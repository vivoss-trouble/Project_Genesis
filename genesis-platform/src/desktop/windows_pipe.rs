use crate::{IpcClient, IpcListener, IpcStream, PlatformError};
use std::time::Duration;

#[cfg(target_os = "windows")]
use std::{fs, io::Read, io::Write, os::windows::io::FromRawHandle};

#[cfg(target_os = "windows")]
use windows_sys::Win32::{
    Foundation::{CloseHandle, ERROR_PIPE_CONNECTED, GetLastError, INVALID_HANDLE_VALUE},
    Storage::FileSystem::PIPE_ACCESS_DUPLEX,
    System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_TYPE_BYTE,
        PIPE_UNLIMITED_INSTANCES, PIPE_WAIT, WaitNamedPipeW,
    },
};

#[cfg(target_os = "windows")]
pub(super) fn connect(
    pipe_name: String,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcClient>, PlatformError> {
    wait_for_pipe(&pipe_name, timeout)?;
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe_name)
        .map_err(PlatformError::io)?;
    Ok(Box::new(Client { file }))
}

#[cfg(not(target_os = "windows"))]
pub(super) fn connect(_: String, _: Option<Duration>) -> Result<Box<dyn IpcClient>, PlatformError> {
    Err(PlatformError::unsupported(
        "Windows named-pipe IPC transport is not supported on this target",
    ))
}

#[cfg(target_os = "windows")]
pub(super) fn connect_streaming(
    pipe_name: String,
    timeout: Option<Duration>,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    wait_for_pipe(&pipe_name, timeout)?;
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(pipe_name)
        .map_err(PlatformError::io)?;
    Ok(Box::new(Client { file }))
}

#[cfg(not(target_os = "windows"))]
pub(super) fn connect_streaming(
    _: String,
    _: Option<Duration>,
) -> Result<Box<dyn IpcStream>, PlatformError> {
    Err(PlatformError::unsupported(
        "Windows named-pipe streaming IPC transport is not supported on this target",
    ))
}

#[cfg(target_os = "windows")]
pub(super) fn bind(pipe_name: String) -> Result<Box<dyn IpcListener>, PlatformError> {
    Ok(Box::new(Listener { pipe_name }))
}

#[cfg(not(target_os = "windows"))]
pub(super) fn bind(_: String) -> Result<Box<dyn IpcListener>, PlatformError> {
    Err(PlatformError::unsupported(
        "Windows named-pipe service listener is not supported on this target",
    ))
}

#[cfg(target_os = "windows")]
struct Client {
    file: fs::File,
}

#[cfg(target_os = "windows")]
struct Listener {
    pipe_name: String,
}

#[cfg(target_os = "windows")]
impl IpcClient for Client {
    fn send(&mut self, payload: &[u8], _timeout: Duration) -> Result<(), PlatformError> {
        self.file.write_all(payload).map_err(PlatformError::io)?;
        self.file.flush().map_err(PlatformError::io)
    }

    fn request(&mut self, payload: &[u8], timeout: Duration) -> Result<Vec<u8>, PlatformError> {
        IpcClient::send(self, payload, timeout)?;

        let mut response = Vec::new();
        self.file
            .read_to_end(&mut response)
            .map_err(PlatformError::io)?;
        Ok(response)
    }
}

#[cfg(target_os = "windows")]
impl IpcStream for Client {
    fn send(&mut self, payload: &[u8], timeout: Duration) -> Result<(), PlatformError> {
        IpcClient::send(self, payload, timeout)
    }

    fn set_nonblocking(&mut self, _nonblocking: bool) -> Result<(), PlatformError> {
        Err(PlatformError::unsupported(
            "named-pipe nonblocking mode is not implemented yet",
        ))
    }

    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, PlatformError> {
        self.file.read(buffer).map_err(PlatformError::io)
    }
}

#[cfg(target_os = "windows")]
impl IpcListener for Listener {
    fn accept(&self) -> Result<Box<dyn IpcStream>, PlatformError> {
        let file = create_pipe_instance(&self.pipe_name)?;
        Ok(Box::new(Client { file }))
    }
}

#[cfg(target_os = "windows")]
fn wait_for_pipe(pipe_name: &str, timeout: Option<Duration>) -> Result<(), PlatformError> {
    let Some(timeout) = timeout else {
        return Ok(());
    };
    let pipe_name = wide_string(pipe_name);
    let timeout_ms = duration_to_millis(timeout);
    let ok = unsafe { WaitNamedPipeW(pipe_name.as_ptr(), timeout_ms) };
    if ok == 0 {
        return Err(PlatformError::io(std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn create_pipe_instance(pipe_name: &str) -> Result<fs::File, PlatformError> {
    let pipe_name = wide_string(pipe_name);
    let handle = unsafe {
        CreateNamedPipeW(
            pipe_name.as_ptr(),
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            0,
            std::ptr::null(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(PlatformError::io(std::io::Error::last_os_error()));
    }

    let connected = unsafe { ConnectNamedPipe(handle, std::ptr::null_mut()) };
    if connected == 0 {
        let error = unsafe { GetLastError() };
        if error != ERROR_PIPE_CONNECTED {
            let io_error = std::io::Error::last_os_error();
            unsafe {
                CloseHandle(handle);
            }
            return Err(PlatformError::io(io_error));
        }
    }

    // The pipe handle is now owned by File and will be closed when the stream drops.
    Ok(unsafe { fs::File::from_raw_handle(handle as _) })
}

#[cfg(target_os = "windows")]
fn wide_string(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(target_os = "windows")]
fn duration_to_millis(duration: Duration) -> u32 {
    duration.as_millis().min(u128::from(u32::MAX)) as u32
}
