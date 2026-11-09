package main

import (
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

//go:embed icon.ico
var iconICO []byte

//go:embed icon.png
var iconPNG []byte

const (
	AppName  = "ZETX DROP"
	Version  = "1.2.0"
	Port     = 8765
	DiscPort = 8766
)

var (
	cfg        *Config
	cfgMu      sync.Mutex
	hub        = NewHub()
	instanceID = randID(8)
	dataDir    string
	relayDir   string
	jobsDir    string
	binDir     string
	quitCh     = make(chan struct{})
)

// ---------------- Config ----------------

type Config struct {
	DeviceName  string `json:"deviceName"`
	SaveDir     string `json:"saveDir"`
	Receive     bool   `json:"receive"`
	QuitOnClose bool   `json:"quitOnClose"`
	ShortcutURL string `json:"shortcutURL"`
	Autostart   bool   `json:"autostart"`
}

func loadConfig() {
	c := &Config{Receive: true}
	b, err := os.ReadFile(filepath.Join(dataDir, "settings.json"))
	firstRun := err != nil
	if err == nil {
		_ = json.Unmarshal(b, c)
	} else {
		c.Receive = true
		c.Autostart = true
	}
	if c.DeviceName == "" {
		h, _ := os.Hostname()
		if h == "" {
			h = "PC"
		}
		c.DeviceName = h
	}
	if c.SaveDir == "" {
		c.SaveDir = filepath.Join(downloadsDir(), AppName)
	}
	cfg = c
	_ = os.MkdirAll(cfg.SaveDir, 0o755)
	if c.Autostart {
		go setAutostart(true) // refresh path in case the exe was moved
	}
	if firstRun {
		saveConfig()
	}
}

func saveConfig() {
	b, _ := json.MarshalIndent(cfg, "", "  ")
	_ = os.WriteFile(filepath.Join(dataDir, "settings.json"), b, 0o644)
}

func getCfg() Config { cfgMu.Lock(); defer cfgMu.Unlock(); return *cfg }

// ---------------- Hub (clients, peers, transfers) ----------------

type Client struct {
	ID, Name, Kind string
	Local          bool
	subs           map[chan []byte]bool
	conns          int
	gone           time.Time
}

type Peer struct {
	ID, Name, IP string
	Port         int
	last         time.Time
}

type Transfer struct {
	ID      string `json:"id"`
	To      string `json:"-"`
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	From    string `json:"from"`
	Path    string `json:"-"`
	Created int64  `json:"created"`
	Kind    string `json:"kind"` // file | media
}

type Received struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	From string `json:"from"`
	Path string `json:"path"`
	Time int64  `json:"time"`
}

type Hub struct {
	mu        sync.Mutex
	clients   map[string]*Client
	peers     map[string]*Peer
	transfers map[string]*Transfer
	received  []Received
}

func NewHub() *Hub {
	return &Hub{clients: map[string]*Client{}, peers: map[string]*Peer{}, transfers: map[string]*Transfer{}}
}

type DeviceInfo struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Kind string `json:"kind"`
	IP   string `json:"ip,omitempty"`
}

func (h *Hub) devicesLocked() []DeviceInfo {
	c := getCfg()
	out := []DeviceInfo{{ID: "host", Name: c.DeviceName, Kind: "host"}}
	var rest []DeviceInfo
	for _, cl := range h.clients {
		if cl.Local {
			continue
		}
		rest = append(rest, DeviceInfo{ID: cl.ID, Name: cl.Name, Kind: cl.Kind})
	}
	for _, p := range h.peers {
		rest = append(rest, DeviceInfo{ID: "peer:" + p.ID, Name: p.Name, Kind: "peer", IP: p.IP})
	}
	sort.Slice(rest, func(i, j int) bool { return rest[i].Name < rest[j].Name })
	return append(out, rest...)
}

func (h *Hub) broadcastDevices() {
	h.mu.Lock()
	d := h.devicesLocked()
	h.mu.Unlock()
	h.broadcast(map[string]any{"type": "devices", "devices": d})
}

// push delivers to every open connection of the client (e.g. two tabs on one phone).
func (h *Hub) push(cl *Client, b []byte) {
	for ch := range cl.subs {
		select {
		case ch <- b:
		default:
		}
	}
}

func (h *Hub) broadcast(v any) {
	b, _ := json.Marshal(v)
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, cl := range h.clients {
		if cl.conns > 0 {
			h.push(cl, b)
		}
	}
}

func (h *Hub) send(id string, v any) {
	b, _ := json.Marshal(v)
	h.mu.Lock()
	defer h.mu.Unlock()
	if cl, ok := h.clients[id]; ok {
		h.push(cl, b)
	}
}

func (h *Hub) sendLocal(v any) {
	b, _ := json.Marshal(v)
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, cl := range h.clients {
		if cl.Local && cl.conns > 0 {
			h.push(cl, b)
		}
	}
}

func (h *Hub) clientName(id string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if id == "host" {
		return getCfg().DeviceName
	}
	if cl, ok := h.clients[id]; ok {
		if cl.Local {
			return getCfg().DeviceName
		}
		return cl.Name
	}
	return ""
}

func (h *Hub) hasClient(id string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.clients[id]
	return ok
}

func (h *Hub) addTransfer(t *Transfer) {
	h.mu.Lock()
	h.transfers[t.ID] = t
	h.mu.Unlock()
	h.send(t.To, map[string]any{"type": "incoming", "transfer": t})
}

func (h *Hub) addReceived(r Received) {
	h.mu.Lock()
	h.received = append([]Received{r}, h.received...)
	if len(h.received) > 200 {
		h.received = h.received[:200]
	}
	h.mu.Unlock()
	h.sendLocal(map[string]any{"type": "received", "item": r})
	notifyReceived(r.Name, r.From)
}

func (h *Hub) localUIWatch() {
	seen := false
	var lastSeen time.Time
	for {
		time.Sleep(2 * time.Second)
		h.mu.Lock()
		on := false
		for _, cl := range h.clients {
			if cl.Local && cl.conns > 0 {
				on = true
			}
		}
		h.mu.Unlock()
		if on {
			seen, lastSeen = true, time.Now()
			continue
		}
		if seen && time.Since(lastSeen) > 8*time.Second {
			seen = false
			if getCfg().QuitOnClose {
				close(quitCh)
				return
			}
			notifyBackground()
		}
	}
}

func (h *Hub) janitor() {
	for {
		time.Sleep(15 * time.Second)
		changed := false
		h.mu.Lock()
		now := time.Now()
		for id, cl := range h.clients {
			if cl.conns <= 0 && now.Sub(cl.gone) > 45*time.Second {
				delete(h.clients, id)
				changed = true
			}
		}
		for id, p := range h.peers {
			if now.Sub(p.last) > 12*time.Second {
				delete(h.peers, id)
				changed = true
			}
		}
		for id, t := range h.transfers {
			if now.Unix()-t.Created > 6*3600 {
				os.Remove(t.Path)
				delete(h.transfers, id)
			}
		}
		h.mu.Unlock()
		if changed {
			h.broadcastDevices()
		}
	}
}

// ---------------- helpers ----------------

func randID(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func isLocal(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func remoteIP(r *http.Request) string {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func jerr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": msg})
}

var badChars = strings.NewReplacer("<", "_", ">", "_", ":", "_", "\"", "_", "/", "_", "\\", "_", "|", "_", "?", "_", "*", "_")

func sanitizeName(n string) string {
	n = strings.ReplaceAll(n, "\\", "/")
	n = filepath.Base(n)
	n = badChars.Replace(n)
	var b strings.Builder
	for _, r := range n {
		if r < 32 {
			continue
		}
		b.WriteRune(r)
	}
	n = strings.Trim(b.String(), " .")
	if n == "" || n == "." || n == ".." {
		n = "dosya"
	}
	if len([]rune(n)) > 180 {
		ext := filepath.Ext(n)
		r := []rune(strings.TrimSuffix(n, ext))
		if len(r) > 170 {
			r = r[:170]
		}
		n = string(r) + ext
	}
	return n
}

func uniquePath(dir, name string) string {
	p := filepath.Join(dir, name)
	if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
		return p
	}
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for i := 1; i < 10000; i++ {
		p = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", base, i, ext))
		if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
			return p
		}
	}
	return filepath.Join(dir, randID(4)+"_"+name)
}

// copyToFile streams body to path with a large buffer (fast, low memory).
func copyToFile(path string, body io.Reader) (int64, error) {
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	tmp := path + ".zxpart"
	f, err := os.Create(tmp)
	if err != nil {
		return 0, err
	}
	buf := make([]byte, 4<<20)
	n, err := io.CopyBuffer(f, body, buf)
	cerr := f.Close()
	if err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return n, err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return n, err
	}
	return n, nil
}

func moveFile(src, dst string) error {
	_ = os.MkdirAll(filepath.Dir(dst), 0o755)
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	_, err = copyToFile(dst, in)
	in.Close()
	if err == nil {
		os.Remove(src)
	}
	return err
}

func lanIPs() []string {
	type cand struct {
		ip   string
		prio int
	}
	var cs []cand
	ifs, _ := net.Interfaces()
	for _, it := range ifs {
		if it.Flags&net.FlagUp == 0 || it.Flags&net.FlagLoopback != 0 {
			continue
		}
		lname := strings.ToLower(it.Name)
		virt := false
		for _, k := range []string{"vethernet", "virtualbox", "vmware", "hyper-v", "wsl", "docker", "vbox", "tailscale", "zerotier", "hamachi", "loopback", "bluetooth"} {
			if strings.Contains(lname, k) {
				virt = true
			}
		}
		addrs, _ := it.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipn.IP.To4()
			if ip4 == nil || ip4[0] == 169 && ip4[1] == 254 {
				continue
			}
			p := 5
			switch {
			case ip4[0] == 192 && ip4[1] == 168:
				p = 1
			case ip4[0] == 10:
				p = 2
			case ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31:
				p = 3
			}
			if virt {
				p += 10
			}
			cs = append(cs, cand{ip4.String(), p})
		}
	}
	sort.SliceStable(cs, func(i, j int) bool { return cs[i].prio < cs[j].prio })
	var out []string
	for _, c := range cs {
		out = append(out, c.ip)
	}
	return out
}

// ---------------- HTTP handlers ----------------

func handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "stream yok", 500)
		return
	}
	q := r.URL.Query()
	id := q.Get("id")
	if id == "" || len(id) > 64 {
		http.Error(w, "id gerekli", 400)
		return
	}
	name := strings.TrimSpace(q.Get("name"))
	if name == "" {
		name = "Cihaz"
	}
	if len([]rune(name)) > 40 {
		name = string([]rune(name)[:40])
	}
	kind := q.Get("kind")
	local := isLocal(r) && kind == "hostui"

	hub.mu.Lock()
	cl, exists := hub.clients[id]
	if !exists {
		cl = &Client{ID: id, subs: map[chan []byte]bool{}}
		hub.clients[id] = cl
	}
	myCh := make(chan []byte, 256)
	cl.subs[myCh] = true
	cl.Name, cl.Kind, cl.Local = name, kind, local
	cl.conns++
	var pending []*Transfer
	for _, t := range hub.transfers {
		if t.To == id {
			pending = append(pending, t)
		}
	}
	hub.mu.Unlock()
	hub.broadcastDevices()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	fmt.Fprintf(w, "retry: 2000\n\n")
	hub.mu.Lock()
	d := hub.devicesLocked()
	hub.mu.Unlock()
	b, _ := json.Marshal(map[string]any{"type": "devices", "devices": d})
	fmt.Fprintf(w, "data: %s\n\n", b)
	sort.Slice(pending, func(i, j int) bool { return pending[i].Created < pending[j].Created })
	for _, t := range pending {
		b, _ := json.Marshal(map[string]any{"type": "incoming", "transfer": t})
		fmt.Fprintf(w, "data: %s\n\n", b)
	}
	fl.Flush()

	ping := time.NewTicker(15 * time.Second)
	defer ping.Stop()
	defer func() {
		hub.mu.Lock()
		delete(cl.subs, myCh)
		cl.conns--
		if cl.conns <= 0 {
			cl.gone = time.Now()
		}
		hub.mu.Unlock()
		hub.broadcastDevices()
	}()
	for {
		select {
		case <-r.Context().Done():
			return
		case msg := <-myCh:
			fmt.Fprintf(w, "data: %s\n\n", msg)
			fl.Flush()
		case <-ping.C:
			fmt.Fprintf(w, ": ping\n\n")
			fl.Flush()
		}
	}
}

func handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodPut {
		jerr(w, 405, "POST gerekli")
		return
	}
	q := r.URL.Query()
	to := q.Get("to")
	from := q.Get("from")
	name, _ := url.QueryUnescape(r.Header.Get("X-File-Name"))
	name = sanitizeName(name)
	fromName := hub.clientName(from)
	if fromName == "" {
		fromName, _ = url.QueryUnescape(r.Header.Get("X-From-Name"))
		if fromName == "" {
			fromName = remoteIP(r)
		}
	}
	size := r.ContentLength

	switch {
	case to == "host":
		c := getCfg()
		if !c.Receive && !isLocal(r) {
			jerr(w, 403, "Bu PC şu an dosya almayı kapattı")
			return
		}
		path := uniquePath(c.SaveDir, name)
		n, err := copyToFile(path, r.Body)
		if err != nil {
			jerr(w, 500, "Kaydedilemedi: "+err.Error())
			return
		}
		hub.addReceived(Received{Name: filepath.Base(path), Size: n, From: fromName, Path: path, Time: time.Now().Unix()})
		writeJSON(w, 200, map[string]any{"ok": true, "size": n})

	case strings.HasPrefix(to, "peer:"):
		hub.mu.Lock()
		p := hub.peers[strings.TrimPrefix(to, "peer:")]
		hub.mu.Unlock()
		if p == nil {
			jerr(w, 404, "Hedef PC bulunamadı")
			return
		}
		if err := forwardToPeer(p, name, fromName, r.Body, size); err != nil {
			jerr(w, 502, err.Error())
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true})

	default:
		if !hub.hasClient(to) {
			jerr(w, 404, "Hedef cihaz çevrim dışı")
			return
		}
		tid := randID(8)
		path := filepath.Join(relayDir, tid)
		n, err := copyToFile(path, r.Body)
		if err != nil {
			jerr(w, 500, "Aktarım kesildi: "+err.Error())
			return
		}
		hub.addTransfer(&Transfer{ID: tid, To: to, Name: name, Size: n, From: fromName, Path: path, Created: time.Now().Unix(), Kind: "file"})
		writeJSON(w, 200, map[string]any{"ok": true, "size": n})
	}
}

var peerHTTP = &http.Client{Transport: &http.Transport{
	WriteBufferSize: 4 << 20, ReadBufferSize: 1 << 20, DisableCompression: true,
	ResponseHeaderTimeout: 0,
}}

func forwardToPeer(p *Peer, name, fromName string, body io.Reader, size int64) error {
	u := fmt.Sprintf("http://%s:%d/api/send?to=host", p.IP, p.Port)
	req, err := http.NewRequest("POST", u, body)
	if err != nil {
		return err
	}
	if size > 0 {
		req.ContentLength = size
	}
	req.Header.Set("X-File-Name", url.QueryEscape(name))
	req.Header.Set("X-From-Name", url.QueryEscape(fromName))
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := peerHTTP.Do(req)
	if err != nil {
		return fmt.Errorf("Hedef PC'ye ulaşılamadı: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		var e struct{ Error string }
		_ = json.NewDecoder(resp.Body).Decode(&e)
		if e.Error == "" {
			e.Error = resp.Status
		}
		return errors.New(e.Error)
	}
	return nil
}

var mediaTypes = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp",
	".heic": "image/heic", ".heif": "image/heif", ".avif": "image/avif", ".bmp": "image/bmp",
	".mp4": "video/mp4", ".m4v": "video/x-m4v", ".mov": "video/quicktime", ".webm": "video/webm", ".mkv": "video/x-matroska",
	".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac", ".wav": "audio/wav",
}

func handleRelay(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/relay/")
	parts := strings.Split(rest, "/")
	tid := parts[0]
	hub.mu.Lock()
	t := hub.transfers[tid]
	hub.mu.Unlock()
	if t == nil {
		http.Error(w, "Dosya artık mevcut değil", 404)
		return
	}
	if len(parts) > 1 && parts[1] == "dismiss" {
		hub.mu.Lock()
		delete(hub.transfers, tid)
		hub.mu.Unlock()
		os.Remove(t.Path)
		writeJSON(w, 200, map[string]any{"ok": true})
		return
	}
	f, err := os.Open(t.Path)
	if err != nil {
		http.Error(w, "Dosya açılamadı", 404)
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	disp := "attachment"
	if r.URL.Query().Get("inline") == "1" {
		disp = "inline"
	}
	ascii := strings.Map(func(r rune) rune {
		if r > 127 || r == '"' {
			return '_'
		}
		return r
	}, t.Name)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`%s; filename="%s"; filename*=UTF-8''%s`, disp, ascii, url.PathEscape(t.Name)))
	if ct, ok := mediaTypes[strings.ToLower(filepath.Ext(t.Name))]; ok {
		w.Header().Set("Content-Type", ct) // so iPhone Shortcuts recognises photos/videos
	}
	http.ServeContent(w, r, t.Name, st.ModTime(), f)
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	c := getCfg()
	writeJSON(w, 200, map[string]any{
		"app": AppName, "version": Version, "name": c.DeviceName, "ips": lanIPs(), "port": Port,
		"receive": c.Receive, "saveDir": c.SaveDir, "shortcutURL": c.ShortcutURL, "httpsPort": HTTPSPort, "https": caDER != nil, "local": isLocal(r), "you": remoteIP(r),
	})
}

func handleSettings(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r) {
		jerr(w, 403, "Sadece bu PC'den")
		return
	}
	if r.Method == http.MethodPost {
		var in struct {
			DeviceName  *string `json:"deviceName"`
			SaveDir     *string `json:"saveDir"`
			Receive     *bool   `json:"receive"`
			QuitOnClose *bool   `json:"quitOnClose"`
			ShortcutURL *string `json:"shortcutURL"`
			Autostart   *bool   `json:"autostart"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			jerr(w, 400, "geçersiz")
			return
		}
		cfgMu.Lock()
		if in.DeviceName != nil && strings.TrimSpace(*in.DeviceName) != "" {
			n := strings.TrimSpace(*in.DeviceName)
			if len([]rune(n)) > 40 {
				n = string([]rune(n)[:40])
			}
			cfg.DeviceName = n
		}
		if in.SaveDir != nil && strings.TrimSpace(*in.SaveDir) != "" {
			d := strings.TrimSpace(*in.SaveDir)
			if err := os.MkdirAll(d, 0o755); err != nil {
				cfgMu.Unlock()
				jerr(w, 400, "Klasör oluşturulamadı: "+err.Error())
				return
			}
			cfg.SaveDir = d
		}
		if in.Receive != nil {
			cfg.Receive = *in.Receive
		}
		if in.ShortcutURL != nil {
			u := strings.TrimSpace(*in.ShortcutURL)
			if u != "" && !strings.HasPrefix(u, "https://www.icloud.com/shortcuts/") {
				cfgMu.Unlock()
				jerr(w, 400, "Bağlantı https://www.icloud.com/shortcuts/ ile başlamalı")
				return
			}
			cfg.ShortcutURL = u
		}
		if in.Autostart != nil {
			if err := setAutostart(*in.Autostart); err != nil {
				cfgMu.Unlock()
				jerr(w, 500, err.Error())
				return
			}
			cfg.Autostart = *in.Autostart
		}
		if in.QuitOnClose != nil {
			cfg.QuitOnClose = *in.QuitOnClose
		}
		saveConfig()
		cfgMu.Unlock()
		hub.broadcastDevices()
	}
	writeJSON(w, 200, map[string]any{"ok": true, "settings": getCfg()})
}

func handleReceivedList(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r) {
		jerr(w, 403, "Sadece bu PC'den")
		return
	}
	hub.mu.Lock()
	list := append([]Received(nil), hub.received...)
	hub.mu.Unlock()
	writeJSON(w, 200, map[string]any{"ok": true, "items": list})
}

func handleOpen(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r) {
		jerr(w, 403, "Sadece bu PC'den")
		return
	}
	p := r.URL.Query().Get("path")
	mode := r.URL.Query().Get("mode")
	c := getCfg()
	if p == "" {
		p = c.SaveDir
		mode = "folder"
	}
	abs, _ := filepath.Abs(p)
	root, _ := filepath.Abs(c.SaveDir)
	if !strings.HasPrefix(strings.ToLower(abs), strings.ToLower(root)) {
		jerr(w, 403, "İzin yok")
		return
	}
	openPath(abs, mode)
	writeJSON(w, 200, map[string]any{"ok": true})
}

func handleFirewall(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r) {
		jerr(w, 403, "Sadece bu PC'den")
		return
	}
	if err := addFirewallRule(); err != nil {
		jerr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func handleQuit(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r) {
		jerr(w, 403, "Sadece bu PC'den")
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
	go func() { time.Sleep(300 * time.Millisecond); close(quitCh) }()
}

func handlePing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	writeJSON(w, 200, map[string]any{"app": "zetxdrop", "id": instanceID})
}

// ---------------- Discovery (PC <-> PC) ----------------

type beacon struct {
	App  string `json:"app"`
	ID   string `json:"id"`
	Name string `json:"name"`
	Port int    `json:"port"`
}

func discovery() {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: DiscPort})
	if err != nil {
		return
	}
	go func() {
		buf := make([]byte, 2048)
		for {
			n, src, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			var b beacon
			if json.Unmarshal(buf[:n], &b) != nil || b.App != "zetxdrop" || b.ID == instanceID {
				continue
			}
			hub.mu.Lock()
			p, ok := hub.peers[b.ID]
			changed := !ok || p.Name != b.Name || p.IP != src.IP.String()
			if !ok {
				p = &Peer{ID: b.ID}
				hub.peers[b.ID] = p
			}
			p.Name, p.IP, p.Port, p.last = b.Name, src.IP.String(), b.Port, time.Now()
			hub.mu.Unlock()
			if changed {
				hub.broadcastDevices()
			}
		}
	}()
	for {
		msg, _ := json.Marshal(beacon{App: "zetxdrop", ID: instanceID, Name: getCfg().DeviceName, Port: Port})
		targets := map[string]bool{"255.255.255.255": true}
		ifs, _ := net.Interfaces()
		for _, it := range ifs {
			if it.Flags&net.FlagUp == 0 || it.Flags&net.FlagBroadcast == 0 {
				continue
			}
			addrs, _ := it.Addrs()
			for _, a := range addrs {
				if ipn, ok := a.(*net.IPNet); ok {
					if ip4 := ipn.IP.To4(); ip4 != nil && !ip4.IsLoopback() {
						bc := make(net.IP, 4)
						for i := range ip4 {
							bc[i] = ip4[i] | ^ipn.Mask[len(ipn.Mask)-4+i]
						}
						targets[bc.String()] = true
					}
				}
			}
		}
		for t := range targets {
			_, _ = conn.WriteToUDP(msg, &net.UDPAddr{IP: net.ParseIP(t), Port: DiscPort})
		}
		time.Sleep(3 * time.Second)
	}
}

// ---------------- main ----------------

func setupDirs() {
	dataDir = appDataDir()
	relayDir = filepath.Join(dataDir, "relay")
	jobsDir = filepath.Join(dataDir, "jobs")
	binDir = filepath.Join(dataDir, "bin")
	os.RemoveAll(relayDir)
	os.RemoveAll(jobsDir)
	for _, d := range []string{dataDir, relayDir, jobsDir, binDir} {
		_ = os.MkdirAll(d, 0o755)
	}
}

func alreadyRunning() bool {
	c := &http.Client{Timeout: 1500 * time.Millisecond}
	resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/api/ping", Port))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var p struct{ App string }
	_ = json.NewDecoder(resp.Body).Decode(&p)
	return p.App == "zetxdrop"
}

func localURL() string { return fmt.Sprintf("http://127.0.0.1:%d/", Port) }

func startServer() error {
	mux := http.NewServeMux()
	sub, _ := fs.Sub(webFS, "web")
	static := http.FileServer(http.FS(sub))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		static.ServeHTTP(w, r)
	})
	mux.HandleFunc("/icon.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write(iconPNG)
	})
	mux.HandleFunc("/favicon.ico", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/x-icon")
		w.Write(iconICO)
	})
	mux.HandleFunc("/api/ping", handlePing)
	mux.HandleFunc("/api/events", handleEvents)
	mux.HandleFunc("/api/send", handleSend)
	mux.HandleFunc("/api/relay/", handleRelay)
	mux.HandleFunc("/api/info", handleInfo)
	mux.HandleFunc("/api/settings", handleSettings)
	mux.HandleFunc("/api/received", handleReceivedList)
	mux.HandleFunc("/api/open", handleOpen)
	mux.HandleFunc("/api/firewall", handleFirewall)
	mux.HandleFunc("/api/quit", handleQuit)
	mux.HandleFunc("/api/media/info", handleMediaInfo)
	mux.HandleFunc("/api/media/download", handleMediaDownload)
	mux.HandleFunc("/api/media/cancel", handleMediaCancel)
	mux.HandleFunc("/api/tools", handleTools)
	mux.HandleFunc("/ZETX-DROP.mobileconfig", handleProfile)

	ln, err := net.Listen("tcp4", ":"+strconv.Itoa(Port))
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 20 * time.Second, MaxHeaderBytes: 1 << 20}
	go srv.Serve(ln)
	if err := startHTTPS(mux); err != nil {
		fmt.Fprintln(os.Stderr, "HTTPS:", err)
	}
	return nil
}

func main() {
	setupDirs()
	if alreadyRunning() {
		openUI(localURL())
		return
	}
	loadConfig()
	if err := startServer(); err != nil {
		showError(fmt.Sprintf("%s başlatılamadı. %d portu kullanımda olabilir.\n\n%v", AppName, Port, err))
		return
	}
	go hub.janitor()
	go hub.localUIWatch()
	go discovery()
	runApp() // platform specific (tray on Windows)
}
