use serde::Serialize;
use std::fmt;

#[derive(Debug, Clone, Copy, Serialize, PartialEq)]
pub struct LogicalPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct DisplayGeometry {
    pub display_id: u32,
    pub logical_origin_x: f64,
    pub logical_origin_y: f64,
    pub logical_width: f64,
    pub logical_height: f64,
    pub pixel_width: usize,
    pub pixel_height: usize,
    pub scale_x: f64,
    pub scale_y: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct DriverProbe {
    pub backend: &'static str,
    pub platform: &'static str,
    pub accessibility_trusted: bool,
    pub main_display: Option<DisplayGeometry>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct DriverReceipt {
    pub backend: &'static str,
    pub action: &'static str,
    pub point: LogicalPoint,
    pub cursor_position: Option<LogicalPoint>,
    pub armed: bool,
    pub posted: bool,
    pub accessibility_trusted: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DriverError {
    UnsupportedPlatform(&'static str),
    InvalidCoordinate(String),
    PermissionRequired(String),
    Native(String),
}

impl fmt::Display for DriverError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedPlatform(message) => f.write_str(message),
            Self::InvalidCoordinate(message)
            | Self::PermissionRequired(message)
            | Self::Native(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for DriverError {}

pub trait GenesisPhysicalDriver {
    fn probe(&self) -> DriverProbe;
    fn move_mouse(&self, point: LogicalPoint, armed: bool) -> Result<DriverReceipt, DriverError>;
    fn click_left(&self, point: LogicalPoint, armed: bool) -> Result<DriverReceipt, DriverError>;
}

pub fn default_driver() -> Box<dyn GenesisPhysicalDriver> {
    platform::default_driver()
}

fn validate_point(point: LogicalPoint) -> Result<(), DriverError> {
    if !point.x.is_finite() || !point.y.is_finite() {
        return Err(DriverError::InvalidCoordinate(
            "physical driver coordinates must be finite".to_string(),
        ));
    }
    if point.x.abs() > 1_000_000.0 || point.y.abs() > 1_000_000.0 {
        return Err(DriverError::InvalidCoordinate(
            "physical driver coordinates exceed absolute safety limit".to_string(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{
        DisplayGeometry, DriverError, DriverProbe, DriverReceipt, GenesisPhysicalDriver,
        LogicalPoint, validate_point,
    };
    use std::ffi::c_void;
    use std::ptr;

    const K_CG_HID_EVENT_TAP: u32 = 0;
    const K_CG_EVENT_LEFT_MOUSE_DOWN: u32 = 1;
    const K_CG_EVENT_LEFT_MOUSE_UP: u32 = 2;
    const K_CG_EVENT_MOUSE_MOVED: u32 = 5;
    const K_CG_MOUSE_BUTTON_LEFT: u32 = 0;
    const K_CG_MOUSE_EVENT_CLICK_STATE: u32 = 1;

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    struct CGPoint {
        x: f64,
        y: f64,
    }

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    struct CGSize {
        width: f64,
        height: f64,
    }

    #[repr(C)]
    #[derive(Debug, Clone, Copy)]
    struct CGRect {
        origin: CGPoint,
        size: CGSize,
    }

    type CGEventRef = *mut c_void;
    type CGEventSourceRef = *mut c_void;

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn AXIsProcessTrusted() -> u8;
        fn CFRelease(cf: *const c_void);
        fn CGDisplayBounds(display: u32) -> CGRect;
        fn CGDisplayPixelsHigh(display: u32) -> usize;
        fn CGDisplayPixelsWide(display: u32) -> usize;
        fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
        fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
        fn CGEventCreateMouseEvent(
            source: CGEventSourceRef,
            mouse_type: u32,
            mouse_cursor_position: CGPoint,
            mouse_button: u32,
        ) -> CGEventRef;
        fn CGEventPost(tap: u32, event: CGEventRef);
        fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
        fn CGWarpMouseCursorPosition(new_cursor_position: CGPoint) -> i32;
        fn CGMainDisplayID() -> u32;
    }

    pub fn default_driver() -> Box<dyn GenesisPhysicalDriver> {
        Box::new(MacCoreGraphicsDriver)
    }

    pub struct MacCoreGraphicsDriver;

    impl GenesisPhysicalDriver for MacCoreGraphicsDriver {
        fn probe(&self) -> DriverProbe {
            DriverProbe {
                backend: "macos-coregraphics",
                platform: "macos",
                accessibility_trusted: accessibility_trusted(),
                main_display: Some(main_display_geometry()),
            }
        }

        fn move_mouse(
            &self,
            point: LogicalPoint,
            armed: bool,
        ) -> Result<DriverReceipt, DriverError> {
            validate_point(point)?;
            if armed {
                require_accessibility()?;
                warp_mouse(point)?;
                post_mouse_event(K_CG_EVENT_MOUSE_MOVED, point)?;
            }
            Ok(receipt("move_mouse", point, armed))
        }

        fn click_left(
            &self,
            point: LogicalPoint,
            armed: bool,
        ) -> Result<DriverReceipt, DriverError> {
            validate_point(point)?;
            if armed {
                require_accessibility()?;
                warp_mouse(point)?;
                post_mouse_event(K_CG_EVENT_MOUSE_MOVED, point)?;
                post_click_event(K_CG_EVENT_LEFT_MOUSE_DOWN, point)?;
                post_click_event(K_CG_EVENT_LEFT_MOUSE_UP, point)?;
            }
            Ok(receipt("click_left", point, armed))
        }
    }

    fn accessibility_trusted() -> bool {
        unsafe { AXIsProcessTrusted() != 0 }
    }

    fn require_accessibility() -> Result<(), DriverError> {
        if accessibility_trusted() {
            Ok(())
        } else {
            Err(DriverError::PermissionRequired(
                "macOS Accessibility permission is required for armed input events".to_string(),
            ))
        }
    }

    fn receipt(action: &'static str, point: LogicalPoint, armed: bool) -> DriverReceipt {
        DriverReceipt {
            backend: "macos-coregraphics",
            action,
            point,
            cursor_position: current_mouse_location(),
            armed,
            posted: armed,
            accessibility_trusted: accessibility_trusted(),
        }
    }

    fn current_mouse_location() -> Option<LogicalPoint> {
        let event = unsafe { CGEventCreate(ptr::null_mut()) };
        if event.is_null() {
            return None;
        }
        let point = unsafe { CGEventGetLocation(event) };
        unsafe {
            CFRelease(event.cast_const());
        }
        Some(LogicalPoint {
            x: point.x,
            y: point.y,
        })
    }

    fn post_mouse_event(mouse_type: u32, point: LogicalPoint) -> Result<(), DriverError> {
        let event = unsafe {
            CGEventCreateMouseEvent(
                ptr::null_mut(),
                mouse_type,
                CGPoint {
                    x: point.x,
                    y: point.y,
                },
                K_CG_MOUSE_BUTTON_LEFT,
            )
        };
        if event.is_null() {
            return Err(DriverError::Native(
                "CGEventCreateMouseEvent returned null".to_string(),
            ));
        }
        unsafe {
            CGEventPost(K_CG_HID_EVENT_TAP, event);
            CFRelease(event.cast_const());
        }
        Ok(())
    }

    fn post_click_event(mouse_type: u32, point: LogicalPoint) -> Result<(), DriverError> {
        let event = unsafe {
            CGEventCreateMouseEvent(
                ptr::null_mut(),
                mouse_type,
                CGPoint {
                    x: point.x,
                    y: point.y,
                },
                K_CG_MOUSE_BUTTON_LEFT,
            )
        };
        if event.is_null() {
            return Err(DriverError::Native(
                "CGEventCreateMouseEvent returned null".to_string(),
            ));
        }
        unsafe {
            CGEventSetIntegerValueField(event, K_CG_MOUSE_EVENT_CLICK_STATE, 1);
            CGEventPost(K_CG_HID_EVENT_TAP, event);
            CFRelease(event.cast_const());
        }
        Ok(())
    }

    fn warp_mouse(point: LogicalPoint) -> Result<(), DriverError> {
        let result = unsafe {
            CGWarpMouseCursorPosition(CGPoint {
                x: point.x,
                y: point.y,
            })
        };
        if result == 0 {
            Ok(())
        } else {
            Err(DriverError::Native(format!(
                "CGWarpMouseCursorPosition failed with status {result}"
            )))
        }
    }

    fn main_display_geometry() -> DisplayGeometry {
        let display_id = unsafe { CGMainDisplayID() };
        let bounds = unsafe { CGDisplayBounds(display_id) };
        let pixel_width = unsafe { CGDisplayPixelsWide(display_id) };
        let pixel_height = unsafe { CGDisplayPixelsHigh(display_id) };
        let scale_x = if bounds.size.width > 0.0 {
            pixel_width as f64 / bounds.size.width
        } else {
            0.0
        };
        let scale_y = if bounds.size.height > 0.0 {
            pixel_height as f64 / bounds.size.height
        } else {
            0.0
        };
        DisplayGeometry {
            display_id,
            logical_origin_x: bounds.origin.x,
            logical_origin_y: bounds.origin.y,
            logical_width: bounds.size.width,
            logical_height: bounds.size.height,
            pixel_width,
            pixel_height,
            scale_x,
            scale_y,
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::{
        DriverError, DriverProbe, DriverReceipt, GenesisPhysicalDriver, LogicalPoint,
        validate_point,
    };

    pub fn default_driver() -> Box<dyn GenesisPhysicalDriver> {
        Box::new(UnsupportedDriver)
    }

    pub struct UnsupportedDriver;

    impl GenesisPhysicalDriver for UnsupportedDriver {
        fn probe(&self) -> DriverProbe {
            DriverProbe {
                backend: "unsupported",
                platform: std::env::consts::OS,
                accessibility_trusted: false,
                main_display: None,
            }
        }

        fn move_mouse(
            &self,
            point: LogicalPoint,
            _armed: bool,
        ) -> Result<DriverReceipt, DriverError> {
            validate_point(point)?;
            Err(DriverError::UnsupportedPlatform(
                "genesis-os-driver currently implements physical input only on macOS",
            ))
        }

        fn click_left(
            &self,
            point: LogicalPoint,
            _armed: bool,
        ) -> Result<DriverReceipt, DriverError> {
            validate_point(point)?;
            Err(DriverError::UnsupportedPlatform(
                "genesis-os-driver currently implements physical input only on macOS",
            ))
        }
    }
}
