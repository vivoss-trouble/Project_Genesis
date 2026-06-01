use crate::{IpcClient, IpcStream, PlatformError};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::time::Duration;

pub(super) fn connect(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcClient>, PlatformError> {
    let stream = connect_stream(host, port, timeout)?;
    Ok(Box::new(Client { stream }))
}

pub(super) fn connect_streaming(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    let stream = connect_stream(host, port, timeout)?;
    Ok(Box::new(Client { stream }))
}

fn connect_stream(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
) -> Result<TcpStream, PlatformError> {
    if let Some(timeout) = timeout {
        let address = (host, port)
            .to_socket_addrs()
            .map_err(PlatformError::io)?
            .next()
            .ok_or_else(|| PlatformError::unavailable("loopback address did not resolve"))?;
        TcpStream::connect_timeout(&address, timeout).map_err(PlatformError::io)
    } else {
        TcpStream::connect((host, port)).map_err(PlatformError::io)
    }
}

struct Client {
    stream: TcpStream,
}

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
