//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

var (
	shell32  = syscall.NewLazyDLL("shell32.dll")
	ole32    = syscall.NewLazyDLL("ole32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")
	pSHGetKF = shell32.NewProc("SHGetKnownFolderPath")
	pCoFree  = ole32.NewProc("CoTaskMemFree")
	pMsgBox  = user32.NewProc("MessageBoxW")
)

func exeName(n string) string { return n + ".exe" }

func appDataDir() string {
	if d := os.Getenv("LOCALAPPDATA"); d != "" {
		return filepath.Join(d, AppName)
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, "AppData", "Local", AppName)
}

// FOLDERID_Downloads {374DE290-123F-4565-9164-39C4925E467B}
var folderIDDownloads = syscall.GUID{Data1: 0x374DE290, Data2: 0x123F, Data3: 0x4565, Data4: [8]byte{0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B}}

func downloadsDir() string {
	var p *uint16
	if pSHGetKF.Find() == nil {
		r, _, _ := pSHGetKF.Call(uintptr(unsafe.Pointer(&folderIDDownloads)), 0, 0, uintptr(unsafe.Pointer(&p)))
		if r == 0 && p != nil {
			s := utf16PtrToString(p)
			pCoFree.Call(uintptr(unsafe.Pointer(p)))
			if s != "" {
				return s
			}
		}
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, "Downloads")
}

func utf16PtrToString(p *uint16) string {
	var buf []uint16
	for ptr := unsafe.Pointer(p); ; ptr = unsafe.Add(ptr, 2) {
		c := *(*uint16)(ptr)
		if c == 0 {
			break
		}
		buf = append(buf, c)
		if len(buf) > 32767 {
			break
		}
	}
	return syscall.UTF16ToString(buf)
}

func hideCmd(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}

func findBrowser() string {
	var cands []string
	for _, env := range []string{"ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"} {
		b := os.Getenv(env)
		if b == "" {
			continue
		}
		cands = append(cands,
			filepath.Join(b, `Microsoft\Edge\Application\msedge.exe`),
			filepath.Join(b, `Google\Chrome\Application\chrome.exe`),
			filepath.Join(b, `BraveSoftware\Brave-Browser\Application\brave.exe`))
	}
	for _, c := range cands {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

func openUI(url string) {
	if b := findBrowser(); b != "" {
		prof := filepath.Join(appDataDir(), "ui-profile")
		cmd := exec.Command(b, "--app="+url, "--user-data-dir="+prof, "--window-size=1220,840",
			"--no-first-run", "--no-default-browser-check", "--disable-features=Translate")
		if cmd.Start() == nil {
			go cmd.Wait()
			return
		}
	}
	c := exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	c.Start()
}

func openPath(p, mode string) {
	switch mode {
	case "select":
		exec.Command("explorer", "/select,"+p).Start()
	case "folder":
		exec.Command("explorer", p).Start()
	default:
		exec.Command("rundll32", "url.dll,FileProtocolHandler", p).Start()
	}
}

func psQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func addFirewallRule() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	inner := fmt.Sprintf(`netsh advfirewall firewall delete rule name="ZETX DROP" & netsh advfirewall firewall add rule name="ZETX DROP" dir=in action=allow program="%s" enable=yes profile=any & netsh advfirewall firewall add rule name="ZETX DROP" dir=in action=allow protocol=TCP localport=%d,%d profile=any & netsh advfirewall firewall add rule name="ZETX DROP" dir=in action=allow protocol=UDP localport=%d profile=any`, exe, Port, HTTPSPort, DiscPort)
	ps := fmt.Sprintf("Start-Process -FilePath cmd.exe -ArgumentList %s -Verb RunAs -WindowStyle Hidden", psQuote("/c "+inner))
	c := exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps)
	hideCmd(c)
	return c.Run()
}

func toast(title, body string) {
	script := fmt.Sprintf(`[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$x = $t.GetElementsByTagName('text')
$x.Item(0).AppendChild($t.CreateTextNode(%s)) > $null
$x.Item(1).AppendChild($t.CreateTextNode(%s)) > $null
$n = [Windows.UI.Notifications.ToastNotification]::new($t)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($n)`, psQuote(title), psQuote(body))
	c := exec.Command("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script)
	hideCmd(c)
	go c.Run()
}

var lastToast time.Time

func notifyReceived(name, from string) {
	if time.Since(lastToast) < 2*time.Second {
		return
	}
	lastToast = time.Now()
	toast("ZETX DROP · Dosya alındı", fmt.Sprintf("%s → %s", from, name))
}

func notifyBackground() {
	toast("ZETX DROP arka planda çalışıyor", "Dosya almaya devam ediyor. Tekrar açmak için ZETX DROP'u çalıştırın.")
}

func showError(msg string) {
	t, _ := syscall.UTF16PtrFromString(AppName)
	m, _ := syscall.UTF16PtrFromString(msg)
	pMsgBox.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), 0x10)
}

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

// setAutostart makes ZETX DROP start silently with Windows so phones can always connect.
func setAutostart(on bool) error {
	var c *exec.Cmd
	if on {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		c = exec.Command("reg", "add", runKey, "/v", AppName, "/t", "REG_SZ", "/d", `"`+exe+`" --autostart`, "/f")
	} else {
		c = exec.Command("reg", "delete", runKey, "/v", AppName, "/f")
	}
	hideCmd(c)
	if err := c.Run(); err != nil && on {
		return fmt.Errorf("Otomatik başlatma ayarlanamadı: %v", err)
	}
	return nil
}

func runApp() {
	silent := false
	for _, a := range os.Args[1:] {
		if a == "--autostart" {
			silent = true
		}
	}
	if !silent {
		openUI(localURL())
	}
	<-quitCh
	os.Exit(0)
}
