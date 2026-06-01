use crate::PlatformError;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoopbackHttpRequest {
    pub method: String,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoopbackHttpResponse {
    pub status: String,
    pub content_type: String,
    pub body: Vec<u8>,
}

impl LoopbackHttpResponse {
    pub fn new(status: impl Into<String>, content_type: impl Into<String>, body: Vec<u8>) -> Self {
        Self {
            status: status.into(),
            content_type: content_type.into(),
            body,
        }
    }
}

pub fn serve(
    addr: &str,
    mut handler: impl FnMut(&LoopbackHttpRequest) -> LoopbackHttpResponse,
) -> Result<(), PlatformError> {
    let listener = TcpListener::bind(addr).map_err(PlatformError::io)?;
    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                if let Some(request) = read_request(&mut stream) {
                    let response = handler(&request);
                    let _ = write_response(&mut stream, response);
                }
            }
            Err(err) => eprintln!("[loopback-http] accept failed: {err}"),
        }
    }
    Ok(())
}

fn read_request(stream: &mut TcpStream) -> Option<LoopbackHttpRequest> {
    let mut buffer = [0_u8; 2048];
    let read = stream.read(&mut buffer).ok()?;
    let request = String::from_utf8_lossy(&buffer[..read]);
    let request_line = request.lines().next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    Some(LoopbackHttpRequest { method, path })
}

fn write_response(
    stream: &mut TcpStream,
    response: LoopbackHttpResponse,
) -> Result<(), PlatformError> {
    let header = format!(
        "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status,
        response.content_type,
        response.body.len()
    );
    stream
        .write_all(header.as_bytes())
        .and_then(|_| stream.write_all(&response.body))
        .map_err(PlatformError::io)
}
