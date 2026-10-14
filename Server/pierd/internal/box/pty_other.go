//go:build !linux && !darwin

package box

import (
	"errors"
	"os"
)

// ptySupported says this box can open a terminal stream (tty.go): not on
// this system.
const ptySupported = false

var errNoPTY = errors.New("this box cannot open a terminal stream")

func openPTY() (ctl, term *os.File, err error) { return nil, nil, errNoPTY }

func setPTYSize(ctl *os.File, cols, rows int) error { return errNoPTY }
