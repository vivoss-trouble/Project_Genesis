use crate::{IpcClient, IpcListener, IpcStream, PlatformError};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::path::Path;
use std::path::PathBuf;
use std::time::Duration;

#[cfg(any(target_os = "macos", target_os = "linux"))]
use socket2::{Domain, SockAddr, Socket, Type};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::{
    fs,
    io::{Read, Write},
    net::Shutdown,
    os::fd::{FromRawFd, IntoRawFd},
};

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn connect(
    path: PathBuf,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcClient>, PlatformError> {
    let stream = if let Some(timeout) = timeout {
        connect_with_timeout(&path, timeout)?
    } else {
        std::os::unix::net::UnixStream::connect(path).map_err(PlatformError::io)?
    };
    Ok(Box::new(Client { stream }))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn connect(
    _: PathBuf,
    _: Option<Duration>,
) -> Result<Box<dyn IpcClient>, PlatformError> {
    Err(PlatformError::unsupported(
        "Unix socket IPC is not supported on this target",
    ))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn connect_streaming(
    path: PathBuf,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    let stream = if let Some(timeout) = timeout {
        connect_with_timeout(&path, timeout)?
    } else {
        std::os::unix::net::UnixStream::connect(path).map_err(PlatformError::io)?
    };
    Ok(Box::new(Client { stream }))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn connect_streaming(
    _: PathBuf,
    _: Option<Duration>,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    Err(PlatformError::unsupported(
        "Unix socket streaming IPC is not supported on this target",
    ))
}

pub(super) fn connect_streaming_path(
    path: &str,
    timeout: Duration,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    connect_streaming(PathBuf::from(path), Some(timeout))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn bind(path: PathBuf) -> Result<Box<dyn IpcListener>, PlatformError> {
    let _ = fs::remove_file(&path);
    let listener = std::os::unix::net::UnixListener::bind(path).map_err(PlatformError::io)?;
    Ok(Box::new(Listener { listener }))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn bind(_: PathBuf) -> Result<Box<dyn IpcListener>, PlatformError> {
    Err(PlatformError::unsupported(
        "Unix socket service listener is not supported on this target",
    ))
}

pub(super) fn bind_path(path: &str) -> Result<Box<dyn IpcListener>, PlatformError> {
    bind(PathBuf::from(path))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
struct Client {
    stream: std::os::unix::net::UnixStream,
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
struct Listener {
    listener: std::os::unix::net::UnixListener,
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
impl IpcClient for Client {
    fn send(&mut self, payload: &[u8], timeout: Duration) -> Result<(), PlatformError> {
        self.stream
            .set_read_timeout(Some(timeout))
            .map_err(PlatformError::io)?;
        self.stream
            .set_write_timeout(Some(timeout))
            .map_err(PlatformError::io)?;
        self.stream.write_all(payload).map_err(PlatformError::io)?;
        self.stream.flush().map_err(PlatformError::io)
    }

    fn request(&mut self, payload: &[u8], timeout: Duration) -> Result<Vec<u8>, PlatformError> {
        IpcClient::send(self, payload, timeout)?;
        let _ = self.stream.shutdown(Shutdown::Write);

        let mut response = Vec::new();
        self.stream
            .read_to_end(&mut response)
            .map_err(PlatformError::io)?;
        Ok(response)
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
impl IpcStream for Client {
    fn send(&mut self, payload: &[u8], timeout: Duration) -> Result<(), PlatformError> {
        IpcClient::send(self, payload, timeout)
    }

    fn set_nonblocking(&mut self, nonblocking: bool) -> Result<(), PlatformError> {
        self.stream
            .set_nonblocking(nonblocking)
            .map_err(PlatformError::io)
    }

    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, PlatformError> {
        self.stream.read(buffer).map_err(PlatformError::io)
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
impl IpcListener for Listener {
    fn accept(&self) -> Result<Box<dyn IpcStream>, PlatformError> {
        let (stream, _) = self.listener.accept().map_err(PlatformError::io)?;
        Ok(Box::new(Client { stream }))
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn connect_with_timeout(
    path: &Path,
    timeout: Duration,
) -> Result<std::os::unix::net::UnixStream, PlatformError> {
    let socket = Socket::new(Domain::UNIX, Type::STREAM, None).map_err(PlatformError::io)?;
    let address = SockAddr::unix(path).map_err(PlatformError::io)?;
    socket
        .connect_timeout(&address, timeout)
        .map_err(PlatformError::io)?;
    let fd = socket.into_raw_fd();
    Ok(unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) })
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod tests {
    use super::*;
    use crate::PlatformErrorKind;
    use std::io::{BufRead, Read, Write};
    use std::thread;

    #[test]
    fn unix_socket_client_requests_response() {
        let (runtime_dir, socket_path) = test_socket("gp-ipc");
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).expect("bind socket");

        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            stream.read_to_end(&mut request).expect("read request");
            assert_eq!(request, b"ping\n");
            stream.write_all(b"pong\n").expect("write response");
        });

        let mut client = connect(socket_path, Some(Duration::from_secs(1))).expect("connect");
        let response = client
            .request(b"ping\n", Duration::from_secs(1))
            .expect("request");

        assert_eq!(response, b"pong\n");
        server.join().expect("server thread");
        let _ = fs::remove_dir_all(runtime_dir);
    }

    #[test]
    fn unix_socket_client_sends_without_response() {
        let (runtime_dir, socket_path) = test_socket("gp-send");
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).expect("bind socket");

        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut line = String::new();
            std::io::BufReader::new(stream)
                .read_line(&mut line)
                .expect("read line");
            assert_eq!(line, "fire\n");
        });

        let mut client = connect(socket_path, Some(Duration::from_secs(1))).expect("connect");
        client
            .send(b"fire\n", Duration::from_secs(1))
            .expect("send");

        server.join().expect("server thread");
        let _ = fs::remove_dir_all(runtime_dir);
    }

    #[test]
    fn unix_socket_stream_supports_nonblocking_read() {
        let (runtime_dir, socket_path) = test_socket("gp-stream");
        let listener = std::os::unix::net::UnixListener::bind(&socket_path).expect("bind socket");

        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = [0_u8; 6];
            stream.read_exact(&mut request).expect("read request");
            assert_eq!(&request, b"hello\n");
            stream.write_all(b"ready\n").expect("write response");
        });

        let mut stream =
            connect_streaming(socket_path, Some(Duration::from_secs(1))).expect("connect");
        stream
            .send(b"hello\n", Duration::from_secs(1))
            .expect("send");
        stream.set_nonblocking(true).expect("nonblocking");

        let mut response = [0_u8; 6];
        for _ in 0..20 {
            match stream.read(&mut response) {
                Ok(6) => break,
                Ok(_) => {}
                Err(err) if err.kind == PlatformErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("stream read failed: {err}"),
            }
        }

        assert_eq!(&response, b"ready\n");
        server.join().expect("server thread");
        let _ = fs::remove_dir_all(runtime_dir);
    }

    fn test_socket(prefix: &str) -> (PathBuf, PathBuf) {
        let temp_root = if PathBuf::from("/private/tmp").is_dir() {
            PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        };
        let runtime_dir = temp_root.join(format!("{prefix}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&runtime_dir);
        fs::create_dir_all(&runtime_dir).expect("runtime dir");
        let socket_path = runtime_dir.join("genesis.sock");
        (runtime_dir, socket_path)
    }
}
