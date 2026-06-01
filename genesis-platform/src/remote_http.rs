use crate::{IpcClient, PlatformError, PlatformErrorKind};
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

pub(crate) fn connect(
    base_url: String,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcClient>, PlatformError> {
    let endpoint = HttpEndpoint::parse(&base_url)?;
    Ok(Box::new(HttpClient { endpoint, timeout }))
}

pub(crate) fn get(
    url: &str,
    timeout: Duration,
    max_response_body: usize,
) -> Result<Vec<u8>, PlatformError> {
    let endpoint = HttpEndpoint::parse(url)?;
    round_trip(&endpoint, "GET", &[], timeout, max_response_body)
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct HttpEndpoint {
    host: String,
    port: u16,
    path: String,
}

impl HttpEndpoint {
    fn parse(raw: &str) -> Result<Self, PlatformError> {
        let without_scheme = raw
            .strip_prefix("http://")
            .ok_or_else(|| PlatformError::unsupported("RemoteHttp currently requires http://"))?;
        let (authority, raw_path) = without_scheme
            .split_once('/')
            .map(|(authority, path)| (authority, format!("/{path}")))
            .unwrap_or((without_scheme, "/".to_string()));
        let (host, port) = authority
            .rsplit_once(':')
            .map(|(host, port)| {
                let parsed_port = port
                    .parse::<u16>()
                    .map_err(|_| PlatformError::invalid("RemoteHttp port must be a u16"))?;
                Ok((host.to_string(), parsed_port))
            })
            .unwrap_or_else(|| Ok((authority.to_string(), 80)))?;

        if host.trim().is_empty() {
            return Err(PlatformError::invalid("RemoteHttp host cannot be empty"));
        }
        if raw_path.contains('#') {
            return Err(PlatformError::invalid(
                "RemoteHttp URL fragments are not supported",
            ));
        }
        Ok(Self {
            host,
            port,
            path: raw_path,
        })
    }

    fn authority(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

struct HttpClient {
    endpoint: HttpEndpoint,
    timeout: Option<Duration>,
}

impl IpcClient for HttpClient {
    fn send(&mut self, payload: &[u8], timeout: Duration) -> Result<(), PlatformError> {
        self.request(payload, timeout).map(|_| ())
    }

    fn request(&mut self, payload: &[u8], timeout: Duration) -> Result<Vec<u8>, PlatformError> {
        let timeout = self.timeout.unwrap_or(timeout);
        round_trip(&self.endpoint, "POST", payload, timeout, usize::MAX)
    }
}

fn round_trip(
    endpoint: &HttpEndpoint,
    method: &str,
    payload: &[u8],
    timeout: Duration,
    max_response_body: usize,
) -> Result<Vec<u8>, PlatformError> {
    let address = (endpoint.host.as_str(), endpoint.port)
        .to_socket_addrs()
        .map_err(PlatformError::io)?
        .next()
        .ok_or_else(|| PlatformError::unavailable("RemoteHttp address did not resolve"))?;
    let mut stream = TcpStream::connect_timeout(&address, timeout).map_err(PlatformError::io)?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(PlatformError::io)?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(PlatformError::io)?;

    let request = format!(
        "{method} {} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        endpoint.path,
        endpoint.authority(),
        payload.len()
    );
    stream
        .write_all(request.as_bytes())
        .and_then(|_| stream.write_all(payload))
        .and_then(|_| stream.flush())
        .map_err(PlatformError::io)?;

    let mut response = Vec::new();
    stream
        .take(max_response_body.saturating_add(4096) as u64)
        .read_to_end(&mut response)
        .map_err(PlatformError::io)?;
    parse_http_response(&response, max_response_body)
}

fn parse_http_response(
    response: &[u8],
    max_response_body: usize,
) -> Result<Vec<u8>, PlatformError> {
    let header_end = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| PlatformError::unavailable("RemoteHttp response missing headers"))?;
    let headers = std::str::from_utf8(&response[..header_end])
        .map_err(|_| PlatformError::unavailable("RemoteHttp response headers were not utf-8"))?;
    let status_line = headers
        .lines()
        .next()
        .ok_or_else(|| PlatformError::unavailable("RemoteHttp response missing status line"))?;
    let status = status_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| PlatformError::unavailable("RemoteHttp response missing status code"))?
        .parse::<u16>()
        .map_err(|_| PlatformError::unavailable("RemoteHttp response status was invalid"))?;
    if !(200..300).contains(&status) {
        return Err(PlatformError {
            kind: PlatformErrorKind::Unavailable,
            message: format!("RemoteHttp returned status {status}"),
        });
    }
    let body = &response[header_end + 4..];
    if body.len() > max_response_body {
        return Err(PlatformError::unavailable(
            "RemoteHttp response body too large",
        ));
    }
    Ok(body.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn parses_http_endpoint_with_default_port() {
        assert_eq!(
            HttpEndpoint::parse("http://example.test/rpc").unwrap(),
            HttpEndpoint {
                host: "example.test".to_string(),
                port: 80,
                path: "/rpc".to_string()
            }
        );
        assert!(HttpEndpoint::parse("https://example.test/rpc").is_err());
    }

    #[test]
    fn remote_http_client_posts_payload_and_returns_body() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let text = read_http_request(&mut stream);
            assert!(text.starts_with("POST /rpc HTTP/1.1\r\n"));
            assert!(text.contains("Content-Length: 6\r\n"));
            assert!(text.ends_with("ping!\n"));
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\npong!\n")
                .expect("write response");
        });

        let mut client = connect(
            format!("http://127.0.0.1:{port}/rpc"),
            Some(Duration::from_secs(1)),
        )
        .unwrap();
        let response = client.request(b"ping!\n", Duration::from_secs(1)).unwrap();

        assert_eq!(response, b"pong!\n");
        server.join().expect("server thread");
    }

    fn read_http_request(stream: &mut TcpStream) -> String {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 128];
        loop {
            let size = stream.read(&mut buffer).expect("read request");
            assert!(size > 0, "request ended before headers");
            request.extend_from_slice(&buffer[..size]);
            if let Some(header_end) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&request[..header_end]).into_owned();
                let content_length = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("Content-Length: "))
                    .expect("content length")
                    .parse::<usize>()
                    .expect("content length number");
                let expected = header_end + 4 + content_length;
                while request.len() < expected {
                    let size = stream.read(&mut buffer).expect("read request body");
                    assert!(size > 0, "request ended before body");
                    request.extend_from_slice(&buffer[..size]);
                }
                return String::from_utf8_lossy(&request).into_owned();
            }
        }
    }
}
