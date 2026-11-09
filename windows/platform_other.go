//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func exeName(n string) string { return n }

func appDataDir() string {
	if d := os.Getenv("ZETX_DATA"); d != "" {
		return d
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".zetxdrop")
}

func downloadsDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, "Downloads")
}

func hideCmd(c *exec.Cmd)              {}
func openUI(url string)                { fmt.Println("UI:", url) }
func openPath(p, mode string)          { fmt.Println("open:", p) }
func addFirewallRule() error           { return nil }
func setAutostart(on bool) error       { return nil }
func notifyReceived(name, from string) {}
func notifyBackground()                {}
func showError(msg string)             { fmt.Fprintln(os.Stderr, msg) }

func runApp() {
	fmt.Println(AppName, "çalışıyor:", localURL())
	<-quitCh
}
