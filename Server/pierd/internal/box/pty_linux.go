package box

import (
	"os"
	"strconv"
	"syscall"
	"unsafe"
)

// ptySupported says this box can open a terminal stream (tty.go).
const ptySupported = true

// openPTY opens a pseudo-terminal pair: the controller pierd reads and
// writes, and the terminal a program runs on. The controller stays in Go's
// poller (its ioctls go through SyscallConn), so closing it ends a read.
func openPTY() (ctl, term *os.File, err error) {
	ctl, err = os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	var n uint32
	if err := ptyIoctl(ctl, syscall.TIOCGPTN, unsafe.Pointer(&n)); err != nil {
		ctl.Close()
		return nil, nil, err
	}
	var unlock int32
	if err := ptyIoctl(ctl, syscall.TIOCSPTLCK, unsafe.Pointer(&unlock)); err != nil {
		ctl.Close()
		return nil, nil, err
	}
	term, err = os.OpenFile("/dev/pts/"+strconv.FormatUint(uint64(n), 10), os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		ctl.Close()
		return nil, nil, err
	}
	return ctl, term, nil
}

// setPTYSize gives the terminal its size in characters; the program on it
// hears SIGWINCH.
func setPTYSize(ctl *os.File, cols, rows int) error {
	ws := struct{ rows, cols, x, y uint16 }{uint16(rows), uint16(cols), 0, 0}
	return ptyIoctl(ctl, syscall.TIOCSWINSZ, unsafe.Pointer(&ws))
}

func ptyIoctl(f *os.File, req uintptr, arg unsafe.Pointer) error {
	rc, err := f.SyscallConn()
	if err != nil {
		return err
	}
	var errno syscall.Errno
	if err := rc.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg))
	}); err != nil {
		return err
	}
	if errno != 0 {
		return errno
	}
	return nil
}
