use mlua::prelude::*;
use os_pipe::PipeWriter;
use reqwest::{ClientBuilder, Method, RequestBuilder, StatusCode, Url, Version};
use std::{io::Write, net::SocketAddr, os::fd::IntoRawFd, time::Duration};
use tokio::{
    sync::mpsc::{error::TryRecvError, UnboundedReceiver, UnboundedSender},
    task::JoinError,
};

struct HttpRequest {
    request: RequestBuilder,
    callback: LuaRegistryKey,
    download_path: Option<String>,
}

async fn do_text_request(req: RequestBuilder) -> anyhow::Result<LuaHttpResponse<String>> {
    let response = req.send().await?;
    let status_code = response.status();
    let url = response.url().clone();
    let version = response.version();
    let content_length = response.content_length();
    let remote_addr = response.remote_addr();

    let headers = response
        .headers()
        .iter()
        .map(|(k, v)| (k.to_string(), v.as_bytes().to_vec()))
        .collect();

    let body = Some(response.text().await?);
    Ok(LuaHttpResponse {
        status_code,
        url,
        version,
        content_length,
        headers,
        remote_addr,
        body,
    })
}

async fn do_download_request(
    req: RequestBuilder,
    download_path: String,
) -> anyhow::Result<LuaHttpResponse<String>> {
    let mut response = req.send().await?;
    let status_code = response.status();
    let url = response.url().clone();
    let version = response.version();
    let content_length = response.content_length();
    let remote_addr = response.remote_addr();

    let headers = response
        .headers()
        .iter()
        .map(|(k, v)| (k.to_string(), v.as_bytes().to_vec()))
        .collect();

    let mut file = std::fs::File::create(download_path)?;
    while let Some(chunk) = response.chunk().await? {
        file.write_all(chunk.as_ref())?;
    }

    Ok(LuaHttpResponse {
        status_code,
        url,
        version,
        content_length,
        headers,
        remote_addr,
        body: None,
    })
}

impl HttpRequest {
    async fn send(self) -> HttpResponse {
        let response = if let Some(download_path) = self.download_path {
            do_download_request(self.request, download_path).await
        } else {
            do_text_request(self.request).await
        };
        HttpResponse {
            response,
            callback: self.callback,
        }
    }
}

struct HttpResponse {
    response: anyhow::Result<LuaHttpResponse<String>>,
    callback: LuaRegistryKey,
}

struct LuaHttpResponse<T> {
    status_code: StatusCode,
    url: Url,
    version: Version,
    content_length: Option<u64>,
    headers: Vec<(String, Vec<u8>)>,
    remote_addr: Option<SocketAddr>,
    body: Option<T>,
}

impl LuaUserData for LuaHttpResponse<String> {
    fn add_fields<'lua, F: LuaUserDataFields<'lua, Self>>(fields: &mut F) {
        fields.add_field_method_get("code", |_, this| -> LuaResult<i32> {
            Ok(this.status_code.as_u16().into())
        });
        fields.add_field_method_get("status", |_, this| -> LuaResult<String> {
            Ok(this.status_code.to_string())
        });
        fields.add_field_method_get("url", |_, this| -> LuaResult<String> {
            Ok(this.url.to_string())
        });
        fields.add_field_method_get("version", |_, this| -> LuaResult<u8> {
            version_to_u8(&this.version)
        });
        fields.add_field_method_get("content_length", |_, this| -> LuaResult<Option<u64>> {
            Ok(this.content_length)
        });
        fields.add_field_method_get("remote_addr", |_, this| -> LuaResult<Option<String>> {
            Ok(this.remote_addr.map(|x| x.to_string()))
        });
        fields.add_field_method_get("body", |_, this| Ok(this.body.clone()));
    }

    fn add_methods<'lua, M: LuaUserDataMethods<'lua, Self>>(methods: &mut M) {
        methods.add_method("get_header_iter", |lua, this, _: ()| {
            let t = lua.create_table()?;
            for (k, v) in this.headers.iter() {
                let ti = lua.create_table()?;
                ti.push(lua.create_string(&k)?)?;
                ti.push(lua.create_string(&v)?)?;
                t.push(ti)?;
            }
            Ok(t)
        })
    }
}

async fn runtime(
    mut request_queue: UnboundedReceiver<HttpRequest>,
    response_queue: UnboundedSender<Result<HttpResponse, JoinError>>,
    ready: PipeWriter,
) {
    let mut pending = Vec::new();
    while let Some(request) = request_queue.recv().await {
        let mut next = Some(request);
        while let Some(request) = next {
            let response_queue = response_queue.clone();
            let mut w = match ready.try_clone() {
                Ok(r) => r,
                Err(_) => return,
            };
            let h = tokio::task::spawn(async move {
                let response = request.send().await;
                response_queue.send(Ok(response)).is_ok() && w.write_all(b"0").is_ok()
            });
            pending.push(h);
            next = match request_queue.try_recv() {
                Ok(v) => Some(v),
                Err(TryRecvError::Empty) => None,
                Err(_) => return,
            };
        }

        let mut i = 0;
        while i < pending.len() {
            if pending[i].is_finished() {
                let j = pending.len() - 1;
                pending.swap(i, j);
                match pending.pop().unwrap().await {
                    Ok(false) => return,
                    Ok(true) => {}
                    Err(e) => match response_queue.send(Err(e)) {
                        Err(_) => return,
                        Ok(_) => {}
                    },
                }
            } else {
                i += 1;
            }
        }
    }
}

fn u8_to_version(v: u8) -> LuaResult<Version> {
    match v {
        0 => Ok(Version::HTTP_09),
        1 => Ok(Version::HTTP_10),
        2 => Ok(Version::HTTP_11),
        3 => Ok(Version::HTTP_2),
        4 => Ok(Version::HTTP_3),
        u => Err(format!("unknown HTTP version {}", u).to_lua_err()),
    }
}

fn version_to_u8(v: &Version) -> LuaResult<u8> {
    match v.clone() {
        Version::HTTP_09 => Ok(0),
        Version::HTTP_10 => Ok(1),
        Version::HTTP_11 => Ok(2),
        Version::HTTP_2 => Ok(3),
        Version::HTTP_3 => Ok(4),
        u => Err(format!("unknown HTTP version {:?}", u).to_lua_err()),
    }
}

#[mlua::lua_module]
fn libhttp_nvim(lua: &Lua) -> LuaResult<LuaTable> {
    let rt = tokio::runtime::Runtime::new()?;
    let (request_send, request_receive) = tokio::sync::mpsc::unbounded_channel();
    let (response_send, mut response_receive) = tokio::sync::mpsc::unbounded_channel();
    let (ready_reader, ready_writer) = os_pipe::pipe().to_lua_err()?;

    rt.spawn(runtime(request_receive, response_send, ready_writer));
    Box::leak(Box::new(rt));

    let exports = lua.create_table()?;

    let ready_reader = ready_reader.into_raw_fd();
    exports.set(
        "get_recv_fd",
        lua.create_function(move |_, _: ()| Ok(ready_reader))?,
    )?;

    exports.set(
        "string_request",
        lua.create_function(
            move |lua,
                  (callback, method, url, headers, body, timeout, version, download_path): (
                LuaFunction,
                String,
                String,
                Vec<[LuaString; 2]>,
                Option<String>,
                Option<f64>,
                Option<u8>,
                Option<String>,
            )|
                  -> LuaResult<()> {
                let client = ClientBuilder::new();
                let method = Method::from_bytes(method.as_bytes()).to_lua_err()?;
                let url: Url = url.parse().to_lua_err()?;
                let mut request = client.build().to_lua_err()?.request(method, url);
                if let Some(body) = body {
                    request = request.body(body)
                }
                if let Some(version) = version {
                    request = request.version(u8_to_version(version)?);
                }
                if let Some(timeout) = timeout {
                    request = request.timeout(Duration::from_millis((timeout * 1000f64) as u64));
                }
                for [key, value] in headers {
                    let key = key.to_str()?;
                    let value = value.as_bytes();
                    request = request.header(key, value);
                }

                let callback = lua.create_registry_value(callback)?;
                request_send
                    .send(HttpRequest {
                        request,
                        callback,
                        download_path,
                    })
                    .map_err(|_| "worker thread has panicked".to_lua_err())
            },
        )?,
    )?;

    exports.set(
        "recv",
        lua.create_function_mut(move |lua, ()| -> LuaResult<Option<LuaFunction>> {
            match response_receive.try_recv() {
                Ok(Ok(v)) => {
                    let f = lua.registry_value::<LuaFunction>(&v.callback);
                    lua.remove_registry_value(v.callback)?;
                    let f = match v.response {
                        Ok(r) => f?.bind((Some(None::<LuaError>), LuaHttpResponse::from(r)))?,
                        Err(r) => {
                            f?.bind((Some(r.to_lua_err()), None::<LuaHttpResponse<String>>))?
                        }
                    };
                    Ok(Some(f))
                }
                Ok(Err(e)) => Err(e).to_lua_err(),
                Err(TryRecvError::Empty) => Ok(None),
                Err(e) => Err(e).to_lua_err(),
            }
        })?,
    )?;
    Ok(exports)
}
