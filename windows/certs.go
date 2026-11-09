package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// HTTPS lets iPhones use the system share sheet ("Save Image / Save Video"),
// which Safari only offers on secure pages. A local CA signs a certificate for
// this PC's LAN IPs. The CA is name-constrained to private IP ranges, so even if
// a phone trusts it, it can never be used to impersonate a real website.

const HTTPSPort = 8767

var (
	caCert    *x509.Certificate
	caKey     *ecdsa.PrivateKey
	caDER     []byte
	leafMu    sync.Mutex
	leafCache *tls.Certificate
	leafKey   string
)

func privateNets() []*net.IPNet {
	var out []*net.IPNet
	for _, c := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10"} {
		_, n, _ := net.ParseCIDR(c)
		out = append(out, n)
	}
	return out
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	return n
}

func loadOrCreateCA() error {
	certP := filepath.Join(dataDir, "zetx-ca.crt")
	keyP := filepath.Join(dataDir, "zetx-ca.key")
	if cb, err := os.ReadFile(certP); err == nil {
		if kb, err := os.ReadFile(keyP); err == nil {
			cblk, _ := pem.Decode(cb)
			kblk, _ := pem.Decode(kb)
			if cblk != nil && kblk != nil {
				c, err1 := x509.ParseCertificate(cblk.Bytes)
				k, err2 := x509.ParseECPrivateKey(kblk.Bytes)
				if err1 == nil && err2 == nil && time.Now().Before(c.NotAfter.Add(-30*24*time.Hour)) {
					caCert, caKey, caDER = c, k, cblk.Bytes
					return nil
				}
			}
		}
	}
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	host, _ := os.Hostname()
	tpl := &x509.Certificate{
		SerialNumber:                serial(),
		Subject:                     pkix.Name{CommonName: "ZETX DROP Yerel Ag (" + host + ")", Organization: []string{"ZETX DROP"}},
		NotBefore:                   time.Now().Add(-24 * time.Hour),
		NotAfter:                    time.Now().AddDate(10, 0, 0),
		IsCA:                        true,
		BasicConstraintsValid:       true,
		MaxPathLenZero:              true,
		KeyUsage:                    x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		PermittedDNSDomainsCritical: true,
		PermittedDNSDomains:         []string{"zetxdrop.invalid"},
		PermittedIPRanges:           privateNets(),
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		return err
	}
	c, _ := x509.ParseCertificate(der)
	kb, _ := x509.MarshalECPrivateKey(k)
	_ = os.WriteFile(certP, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	_ = os.WriteFile(keyP, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600)
	caCert, caKey, caDER = c, k, der
	return nil
}

func leafFor(ips []string) (*tls.Certificate, error) {
	sort.Strings(ips)
	key := strings.Join(ips, ",")
	leafMu.Lock()
	defer leafMu.Unlock()
	if leafCache != nil && leafKey == key && time.Now().Before(leafCache.Leaf.NotAfter.Add(-7*24*time.Hour)) {
		return leafCache, nil
	}
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	var ipAddrs []net.IP
	for _, s := range ips {
		if ip := net.ParseIP(s); ip != nil {
			ipAddrs = append(ipAddrs, ip)
		}
	}
	tpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      pkix.Name{CommonName: "ZETX DROP", Organization: []string{"ZETX DROP"}},
		NotBefore:    time.Now().Add(-24 * time.Hour),
		NotAfter:     time.Now().AddDate(0, 0, 390), // Apple: TLS certs must be ≤ 398 days
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  ipAddrs,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &k.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	leaf, _ := x509.ParseCertificate(der)
	leafCache = &tls.Certificate{Certificate: [][]byte{der, caDER}, PrivateKey: k, Leaf: leaf}
	leafKey = key
	return leafCache, nil
}

func certIPs() []string {
	ips := []string{"127.0.0.1"}
	for _, ip := range lanIPs() {
		p := net.ParseIP(ip)
		for _, n := range privateNets() {
			if n.Contains(p) {
				ips = append(ips, ip)
				break
			}
		}
	}
	return ips
}

func startHTTPS(h http.Handler) error {
	if err := loadOrCreateCA(); err != nil {
		return err
	}
	cfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
		GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			return leafFor(certIPs())
		},
	}
	ln, err := net.Listen("tcp4", fmt.Sprintf(":%d", HTTPSPort))
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: h, TLSConfig: cfg, ReadHeaderTimeout: 20 * time.Second, ErrorLog: nil}
	go srv.ServeTLS(ln, "", "")
	return nil
}

// iOS installs this as a profile: Settings → Profile Downloaded → Install.
func handleProfile(w http.ResponseWriter, r *http.Request) {
	if caDER == nil {
		http.Error(w, errors.New("sertifika hazır değil").Error(), 503)
		return
	}
	uuid1, uuid2 := uuidish(caDER, 1), uuidish(caDER, 2)
	b64 := base64.StdEncoding.EncodeToString(caDER)
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadCertificateFileName</key><string>zetx-drop.cer</string>
			<key>PayloadContent</key><data>` + b64 + `</data>
			<key>PayloadDescription</key><string>ZETX DROP yerel ag sertifikasi</string>
			<key>PayloadDisplayName</key><string>ZETX DROP Yerel Ag</string>
			<key>PayloadIdentifier</key><string>com.zetx.drop.ca.` + uuid1 + `</string>
			<key>PayloadType</key><string>com.apple.security.root</string>
			<key>PayloadUUID</key><string>` + uuid1 + `</string>
			<key>PayloadVersion</key><integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key><string>iPhone'dan ZETX DROP ile fotograf ve videolari dogrudan galeriye kaydetmek icin. Yalnizca ev/ofis agindaki IP adresleri icin gecerlidir.</string>
	<key>PayloadDisplayName</key><string>ZETX DROP</string>
	<key>PayloadIdentifier</key><string>com.zetx.drop.` + uuid2 + `</string>
	<key>PayloadOrganization</key><string>ZETX - Volkan Sezer</string>
	<key>PayloadRemovalDisallowed</key><false/>
	<key>PayloadType</key><string>Configuration</string>
	<key>PayloadUUID</key><string>` + uuid2 + `</string>
	<key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>`
	w.Header().Set("Content-Type", "application/x-apple-aspen-config")
	w.Header().Set("Content-Disposition", `attachment; filename="ZETX-DROP.mobileconfig"`)
	w.Write([]byte(plist))
}

func uuidish(seed []byte, n byte) string {
	h := make([]byte, 16)
	for i := range seed {
		h[i%16] ^= seed[i] + n*byte(i)
	}
	h[6] = h[6]&0x0f | 0x40
	h[8] = h[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", h[0:4], h[4:6], h[6:8], h[8:10], h[10:16]))
}
