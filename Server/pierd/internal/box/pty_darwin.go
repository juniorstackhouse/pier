package box

import (
	"bytes"
	"os"
	"syscall"
	"unsafe"
)

// ptySupported says this box can open a terminal stream (tty.go).
const ptySupported = true

// The macOS pseudo-terminal ioctls (sys/ttycom.h), which package syscall
// does not name.
const (
	tiocPTYGrant = 0x20007454
	tiocPTYUnlk  = 0x20007452
	tiocPTYGName = 0x40807453
)

// openPTY opens a pseudo-terminal pair: the controller pierd reads and
// writes, and the terminal a program runs on.
func openPTY() (ctl, term *os.File, err error) {
	ctl, err = os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	fail := func(err error) (*os.File, *os.File, error) {
		ctl.Close()
		return nil, nil, err
	}
	if err := ptyIoctl(ctl, tiocPTYGrant, nil); err != nil {
		return fail(err)
	}
	if err := ptyIoctl(ctl, tiocPTYUnlk, nil); err != nil {
		return fail(err)
	}
	var name [128]byte
	if err := ptyIoctl(ctl, tiocPTYGName, unsafe.Pointer(&name[0])); err != nil {
		return fail(err)
	}
	path := name[:]
	if i := bytes.IndexByte(path, 0); i >= 0 {
		path = path[:i]
	}
	term, err = os.OpenFile(string(path), os.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return fail(err)
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
