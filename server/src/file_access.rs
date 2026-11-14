use cap_std::fs::{Dir, OpenOptions};
use std::{fs::File, io, path::Path};

/// Keep path resolution inside the media capability and reject special files.
/// A regular file may be replaced by a FIFO after the scan; opening it must
/// never wait for a writer and occupy a blocking worker indefinitely.
pub(crate) fn open_regular(root: &Dir, path: impl AsRef<Path>) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use cap_std::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = root.open_with(path, &options)?.into_std();
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "media must be a regular file",
        ));
    }
    Ok(file)
}

/// Open a cache entry without following any symlink, including directories.
/// Every path component is opened relative to an already held directory FD.
#[cfg(unix)]
pub(crate) fn open_regular_nofollow(root: &Dir, path: impl AsRef<Path>) -> io::Result<File> {
    use std::{
        ffi::CString,
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::ffi::OsStrExt,
        },
        path::Component,
    };

    let components: Vec<_> = path.as_ref().components().collect();
    if components.is_empty()
        || components
            .iter()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid cache path",
        ));
    }
    let mut directory = root.try_clone()?.into_std_file();
    for (index, component) in components.iter().enumerate() {
        let name = CString::new(component.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid cache path"))?;
        let last = index + 1 == components.len();
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if last { 0 } else { libc::O_DIRECTORY };
        // SAFETY: directory owns a live FD, name is NUL-terminated, and flags
        // request no creation. A successful result transfers one owned FD.
        let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new valid descriptor owned by this scope.
        let file = unsafe { File::from_raw_fd(fd) };
        if last {
            if !file.metadata()?.is_file() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "cache must be a regular file",
                ));
            }
            return Ok(file);
        }
        directory = file;
    }
    unreachable!("a nonempty component list returns its last file")
}

#[cfg(not(unix))]
pub(crate) fn open_regular_nofollow(_root: &Dir, _path: impl AsRef<Path>) -> io::Result<File> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "prepared playback requires no-follow file access",
    ))
}
