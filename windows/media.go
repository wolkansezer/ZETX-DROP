package main

import (
	"archive/zip"
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------- External tools (auto-installed on first use) ----------------

type toolDef struct {
	Name string
	File string
	URL  string
	Zip  bool
}

var tools = map[string]toolDef{
	"yt-dlp":     {Name: "yt-dlp", File: exeName("yt-dlp"), URL: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"},
	"gallery-dl": {Name: "gallery-dl", File: exeName("gallery-dl"), URL: "https://github.com/mikf/gallery-dl/releases/latest/download/gallery-dl.exe"},
	"ffmpeg":     {Name: "ffmpeg", File: exeName("ffmpeg"), URL: "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip", Zip: true},
}

var toolLocks = map[string]*sync.Mutex{"yt-dlp": {}, "gallery-dl": {}, "ffmpeg": {}}

func toolPath(name string) string {
	t := tools[name]
	// A copy next to the exe wins (lets users drop their own build)
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), t.File)
		if st, err := os.Stat(p); err == nil && st.Size() > 0 {
			return p
		}
	}
	return filepath.Join(binDir, t.File)
}

func toolExists(name string) bool {
	st, err := os.Stat(toolPath(name))
	return err == nil && st.Size() > 1000
}

type progWriter struct {
	w     io.Writer
	total int64
	done  int64
	last  time.Time
	cb    func(done, total int64)
}

func (p *progWriter) Write(b []byte) (int, error) {
	n, err := p.w.Write(b)
	p.done += int64(n)
	if time.Since(p.last) > 400*time.Millisecond {
		p.last = time.Now()
		p.cb(p.done, p.total)
	}
	return n, err
}

var dlHTTP = &http.Client{Timeout: 30 * time.Minute}

func ensureTool(name string, force bool) error {
	l := toolLocks[name]
	l.Lock()
	defer l.Unlock()
	if !force && toolExists(name) {
		return nil
	}
	t := tools[name]
	label := map[string]string{"yt-dlp": "Video motoru (yt-dlp)", "gallery-dl": "Görsel motoru (gallery-dl)", "ffmpeg": "Dönüştürücü (FFmpeg)"}[name]
	report := func(pct int, msg string) {
		hub.broadcast(map[string]any{"type": "tool", "name": name, "label": label, "pct": pct, "msg": msg})
	}
	report(0, "İndiriliyor…")
	resp, err := dlHTTP.Get(t.URL)
	if err != nil {
		report(-1, "İndirilemedi")
		return fmt.Errorf("%s indirilemedi (internet bağlantısını kontrol edin): %v", label, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		report(-1, "İndirilemedi")
		return fmt.Errorf("%s indirilemedi: %s", label, resp.Status)
	}
	tmp := filepath.Join(binDir, t.File+".download")
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	pw := &progWriter{w: f, total: resp.ContentLength, cb: func(d, tot int64) {
		pct := 0
		if tot > 0 {
			pct = int(d * 100 / tot)
		}
		report(pct, fmt.Sprintf("%.1f / %.1f MB", float64(d)/1e6, float64(tot)/1e6))
	}}
	_, err = io.CopyBuffer(pw, resp.Body, make([]byte, 1<<20))
	f.Close()
	if err != nil {
		os.Remove(tmp)
		report(-1, "İndirme yarıda kaldı")
		return err
	}
	if t.Zip {
		report(99, "Paketten çıkarılıyor…")
		if err := extractFFmpeg(tmp); err != nil {
			os.Remove(tmp)
			report(-1, "Çıkarılamadı")
			return err
		}
		os.Remove(tmp)
	} else {
		dst := filepath.Join(binDir, t.File)
		os.Remove(dst)
		if err := os.Rename(tmp, dst); err != nil {
			return err
		}
	}
	report(100, "Hazır")
	return nil
}

func extractFFmpeg(zipPath string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	found := 0
	for _, f := range zr.File {
		base := strings.ToLower(filepath.Base(f.Name))
		if base != "ffmpeg.exe" && base != "ffprobe.exe" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		_, err = copyToFile(filepath.Join(binDir, base), rc)
		rc.Close()
		if err != nil {
			return err
		}
		found++
	}
	if found == 0 {
		return errors.New("ffmpeg.exe paket içinde bulunamadı")
	}
	return nil
}

func handleTools(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		if !isLocal(r) {
			jerr(w, 403, "Sadece bu PC'den")
			return
		}
		go func() {
			for _, n := range []string{"yt-dlp", "gallery-dl", "ffmpeg"} {
				if err := ensureTool(n, true); err != nil {
					hub.sendLocal(map[string]any{"type": "toast", "msg": err.Error(), "level": "err"})
					return
				}
			}
			hub.sendLocal(map[string]any{"type": "toast", "msg": "İndirme motorları güncellendi", "level": "ok"})
		}()
		writeJSON(w, 200, map[string]any{"ok": true})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "yt-dlp": toolExists("yt-dlp"), "gallery-dl": toolExists("gallery-dl"), "ffmpeg": toolExists("ffmpeg")})
}

// ---------------- Media info ----------------

type mediaReq struct {
	URL     string `json:"url"`
	Mode    string `json:"mode"`   // video | mp3 | image
	Height  int    `json:"height"` // 0 = best
	Bitrate int    `json:"bitrate"`
	Compat  bool   `json:"compat"`
	Cookies string `json:"cookies"` // "", firefox, chrome, edge, brave, opera
	Target  string `json:"target"`  // host | <clientId> | peer:<id>
	From    string `json:"from"`
}

func cookieArgs(c string) []string {
	switch c {
	case "firefox", "chrome", "edge", "brave", "opera", "chromium", "vivaldi":
		return []string{"--cookies-from-browser", c}
	}
	return nil
}

func cleanURL(u string) string {
	u = strings.TrimSpace(u)
	if i := strings.IndexAny(u, " \t\n"); i > 0 {
		u = u[:i]
	}
	return u
}

func handleMediaInfo(w http.ResponseWriter, r *http.Request) {
	var in mediaReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		jerr(w, 400, "geçersiz istek")
		return
	}
	in.URL = cleanURL(in.URL)
	if !strings.HasPrefix(in.URL, "http://") && !strings.HasPrefix(in.URL, "https://") {
		jerr(w, 400, "Geçerli bir bağlantı yapıştırın (https:// ile başlamalı)")
		return
	}
	if err := ensureTool("yt-dlp", false); err != nil {
		jerr(w, 500, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 120*time.Second)
	defer cancel()
	args := []string{"-J", "--no-warnings", "--no-playlist", "--flat-playlist", "--encoding", "utf-8"}
	args = append(args, cookieArgs(in.Cookies)...)
	args = append(args, "--", in.URL)
	cmd := exec.CommandContext(ctx, toolPath("yt-dlp"), args...)
	hideCmd(cmd)
	cmd.Env = append(os.Environ(), "PYTHONIOENCODING=utf-8", "PYTHONUTF8=1")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := lastErrorLine(stderr.String())
		// Image-only posts (Instagram photo, X/Twitter photo, Pinterest...) -> offer image mode
		writeJSON(w, 200, map[string]any{"ok": true, "title": "", "hasVideo": false, "imageOnly": true, "note": msg, "heights": []int{}})
		return
	}
	var info struct {
		Type      string  `json:"_type"`
		Title     string  `json:"title"`
		Thumbnail string  `json:"thumbnail"`
		Duration  float64 `json:"duration"`
		Uploader  string  `json:"uploader"`
		Extractor string  `json:"extractor_key"`
		Height    int     `json:"height"`
		Vcodec    string  `json:"vcodec"`
		Formats   []struct {
			Height int    `json:"height"`
			Vcodec string `json:"vcodec"`
			Acodec string `json:"acodec"`
		} `json:"formats"`
		Entries []json.RawMessage `json:"entries"`
		Thumbs  []struct {
			URL string `json:"url"`
		} `json:"thumbnails"`
	}
	if err := json.Unmarshal(out, &info); err != nil {
		jerr(w, 500, "Bilgi okunamadı")
		return
	}
	hs := map[int]bool{}
	hasVideo, hasAudio := false, false
	for _, f := range info.Formats {
		if f.Vcodec != "" && f.Vcodec != "none" && f.Height > 0 {
			hs[f.Height] = true
			hasVideo = true
		}
		if f.Acodec != "" && f.Acodec != "none" {
			hasAudio = true
		}
	}
	if len(info.Formats) == 0 && info.Height > 0 {
		hs[info.Height] = true
		hasVideo = true
	}
	var heights []int
	for h := range hs {
		heights = append(heights, h)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(heights)))
	thumb := info.Thumbnail
	if thumb == "" && len(info.Thumbs) > 0 {
		thumb = info.Thumbs[len(info.Thumbs)-1].URL
	}
	writeJSON(w, 200, map[string]any{
		"ok": true, "title": info.Title, "thumbnail": thumb, "duration": info.Duration, "uploader": info.Uploader,
		"site": info.Extractor, "heights": heights, "hasVideo": hasVideo || len(info.Formats) > 0, "hasAudio": hasAudio,
		"playlist": info.Type == "playlist", "count": len(info.Entries), "imageOnly": false,
	})
}

func lastErrorLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if strings.HasPrefix(l, "ERROR:") {
			l = strings.TrimSpace(strings.TrimPrefix(l, "ERROR:"))
			if len(l) > 300 {
				l = l[:300] + "…"
			}
			return l
		}
	}
	if len(lines) > 0 {
		l := lines[len(lines)-1]
		if len(l) > 300 {
			l = l[:300]
		}
		return l
	}
	return "Bilinmeyen hata"
}

// ---------------- Media download jobs ----------------

type job struct {
	ID     string
	Req    mediaReq
	cancel context.CancelFunc
}

var (
	jobsMu sync.Mutex
	jobs   = map[string]*job{}
)

func handleMediaDownload(w http.ResponseWriter, r *http.Request) {
	var in mediaReq
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		jerr(w, 400, "geçersiz istek")
		return
	}
	in.URL = cleanURL(in.URL)
	if !strings.HasPrefix(in.URL, "http") {
		jerr(w, 400, "Geçerli bir bağlantı yapıştırın")
		return
	}
	if in.Target == "" {
		in.Target = "host"
	}
	if in.Target == "host" && !isLocal(r) && !getCfg().Receive {
		jerr(w, 403, "PC dosya almayı kapattı")
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	j := &job{ID: randID(6), Req: in, cancel: cancel}
	jobsMu.Lock()
	jobs[j.ID] = j
	jobsMu.Unlock()
	go runJob(ctx, j)
	writeJSON(w, 200, map[string]any{"ok": true, "job": j.ID})
}

func handleMediaCancel(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	jobsMu.Lock()
	j := jobs[id]
	jobsMu.Unlock()
	if j != nil {
		j.cancel()
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (j *job) report(state string, pct float64, speed, eta, msg string) {
	ev := map[string]any{"type": "job", "id": j.ID, "state": state, "pct": pct, "speed": speed, "eta": eta, "msg": msg, "url": j.Req.URL, "mode": j.Req.Mode}
	if j.Req.From != "" {
		hub.send(j.Req.From, ev)
	}
	if j.Req.From == "" || !strings.HasPrefix(j.Req.From, "hostui") {
		hub.sendLocal(ev)
	}
}

func runJob(ctx context.Context, j *job) {
	defer func() {
		jobsMu.Lock()
		delete(jobs, j.ID)
		jobsMu.Unlock()
	}()
	dir := filepath.Join(jobsDir, j.ID)
	_ = os.MkdirAll(dir, 0o755)
	defer os.RemoveAll(dir)
	q := j.Req

	j.report("prep", 0, "", "", "Hazırlanıyor…")
	need := []string{"yt-dlp", "ffmpeg"}
	if q.Mode == "image" {
		need = []string{"gallery-dl"}
	}
	for _, n := range need {
		if err := ensureTool(n, false); err != nil {
			j.report("error", 0, "", "", err.Error())
			return
		}
	}

	var cmd *exec.Cmd
	if q.Mode == "image" {
		args := []string{"-D", dir, "--no-mtime"}
		args = append(args, cookieArgs(q.Cookies)...)
		args = append(args, "--", q.URL)
		cmd = exec.CommandContext(ctx, toolPath("gallery-dl"), args...)
	} else {
		args := []string{
			"--no-playlist", "--newline", "--no-mtime", "--windows-filenames", "--encoding", "utf-8",
			"-N", "8", "--retries", "10", "--fragment-retries", "10",
			"--ffmpeg-location", filepath.Dir(toolPath("ffmpeg")),
			"-P", dir, "-o", "%(title).90B [%(id)s].%(ext)s",
			"--progress-template", "download:ZX|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
		}
		if q.Mode == "mp3" {
			br := q.Bitrate
			if br != 128 && br != 192 && br != 256 && br != 320 {
				br = 320
			}
			args = append(args, "-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", fmt.Sprintf("%dK", br), "--embed-metadata")
		} else {
			args = append(args, "-f", videoSelector(q.Height, q.Compat), "--merge-output-format", "mp4/mkv")
		}
		args = append(args, cookieArgs(q.Cookies)...)
		args = append(args, "--", q.URL)
		cmd = exec.CommandContext(ctx, toolPath("yt-dlp"), args...)
	}
	hideCmd(cmd)
	cmd.Env = append(os.Environ(), "PYTHONIOENCODING=utf-8", "PYTHONUTF8=1")
	stdout, _ := cmd.StdoutPipe()
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		j.report("error", 0, "", "", "Başlatılamadı: "+err.Error())
		return
	}
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	imgCount := 0
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "ZX|"):
			p := strings.Split(line, "|")
			if len(p) >= 4 {
				pct, _ := strconv.ParseFloat(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(p[1]), "%")), 64)
				j.report("dl", pct, strings.TrimSpace(p[2]), strings.TrimSpace(p[3]), "İndiriliyor")
			}
		case strings.HasPrefix(line, "[Merger]"):
			j.report("post", 100, "", "", "Görüntü ve ses birleştiriliyor…")
		case strings.HasPrefix(line, "[ExtractAudio]"):
			j.report("post", 100, "", "", "MP3'e dönüştürülüyor…")
		case q.Mode == "image" && line != "":
			imgCount++
			j.report("dl", 0, "", "", fmt.Sprintf("%d görsel indirildi", imgCount))
		}
	}
	err := cmd.Wait()
	if ctx.Err() != nil {
		j.report("error", 0, "", "", "İptal edildi")
		return
	}
	files := collectFiles(dir)
	if err != nil && len(files) == 0 {
		msg := lastErrorLine(stderr.String())
		if strings.Contains(strings.ToLower(msg), "login") || strings.Contains(strings.ToLower(msg), "cookie") || strings.Contains(msg, "rate-limit") {
			msg += " — İpucu: 'Tarayıcı oturumu' olarak giriş yaptığınız tarayıcıyı (Firefox önerilir) seçip tekrar deneyin."
		}
		j.report("error", 0, "", "", msg)
		return
	}
	if len(files) == 0 {
		j.report("error", 0, "", "", "Bu bağlantıda indirilebilir içerik bulunamadı")
		return
	}
	j.report("post", 100, "", "", "Hedefe aktarılıyor…")
	if err := deliverFiles(files, q); err != nil {
		j.report("error", 0, "", "", err.Error())
		return
	}
	names := []string{}
	for _, f := range files {
		names = append(names, filepath.Base(f))
	}
	j.report("done", 100, "", "", strings.Join(names, ", "))
}

func videoSelector(h int, compat bool) string {
	f := ""
	if h > 0 {
		f = fmt.Sprintf("[height<=%d]", h)
	}
	if compat {
		return fmt.Sprintf("bv*%[1]s[vcodec^=avc]+ba[ext=m4a]/bv*%[1]s[vcodec^=avc]+ba/b%[1]s[vcodec^=avc]/bv*%[1]s+ba/b%[1]s/bv*+ba/b", f)
	}
	return fmt.Sprintf("bv*%[1]s+ba/b%[1]s/bv*+ba/b", f)
}

var fragRe = regexp.MustCompile(`\.f\d+(-\d+)?\.[a-z0-9]+$`)

func collectFiles(dir string) []string {
	var out []string
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		low := strings.ToLower(p)
		for _, s := range []string{".part", ".ytdl", ".temp", ".zxpart", ".json", ".webp.tmp"} {
			if strings.HasSuffix(low, s) {
				return nil
			}
		}
		if fragRe.MatchString(low) {
			return nil // leftover un-merged fragments like video.f137.mp4
		}
		out = append(out, p)
		return nil
	})
	sort.Strings(out)
	return out
}

func deliverFiles(files []string, q mediaReq) error {
	fromName := getCfg().DeviceName + " · Medya"
	for _, f := range files {
		name := sanitizeName(filepath.Base(f))
		st, _ := os.Stat(f)
		switch {
		case q.Target == "host":
			dst := uniquePath(filepath.Join(getCfg().SaveDir, "Medya"), name)
			if err := moveFile(f, dst); err != nil {
				return err
			}
			hub.addReceived(Received{Name: filepath.Base(dst), Size: st.Size(), From: "Medya İndirici", Path: dst, Time: time.Now().Unix()})
		case strings.HasPrefix(q.Target, "peer:"):
			hub.mu.Lock()
			p := hub.peers[strings.TrimPrefix(q.Target, "peer:")]
			hub.mu.Unlock()
			if p == nil {
				return errors.New("Hedef PC bulunamadı")
			}
			in, err := os.Open(f)
			if err != nil {
				return err
			}
			err = forwardToPeer(p, name, fromName, in, st.Size())
			in.Close()
			if err != nil {
				return err
			}
		default:
			if !hub.hasClient(q.Target) {
				return errors.New("Hedef cihaz çevrim dışı")
			}
			tid := randID(8)
			dst := filepath.Join(relayDir, tid)
			if err := moveFile(f, dst); err != nil {
				return err
			}
			hub.addTransfer(&Transfer{ID: tid, To: q.Target, Name: name, Size: st.Size(), From: fromName, Path: dst, Created: time.Now().Unix(), Kind: "media"})
		}
	}
	return nil
}
