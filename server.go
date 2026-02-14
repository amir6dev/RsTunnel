/*
 * RsTunnel Critical Fixes - Part 2: Server Side
 * این فایل fixes مربوط به server-side را شامل میشه
 */

package httpmux

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// ============================================================================
// FIX 2: stripFakeHeaders در سرور
// ============================================================================

// stripFakeHeaders - حذف fake HTTP headers از ابتدای payload
// این تابع باید بعد از decrypt و قبل از ReadFrame صدا زده شود
func stripFakeHeaders(data []byte) []byte {
	// پیدا کردن "\r\n\r\n" که نشان‌دهنده پایان HTTP headers است
	endOfHeaders := bytes.Index(data, []byte("\r\n\r\n"))
	if endOfHeaders == -1 {
		// اگر پیدا نشد، احتمالاً headers وجود ندارد
		return data
	}
	
	// بررسی که آیا این واقعاً HTTP header است؟
	// باید با "POST " یا "GET " شروع شود
	if len(data) < 4 {
		return data
	}
	
	if bytes.HasPrefix(data, []byte("POST ")) || 
	   bytes.HasPrefix(data, []byte("GET ")) ||
	   bytes.HasPrefix(data, []byte("PUT ")) {
		// این احتمالاً fake header است، skip کن
		return data[endOfHeaders+4:] // +4 برای "\r\n\r\n"
	}
	
	return data
}

// ============================================================================
// FIX 3: Validate handshake در HandleHTTP
// ============================================================================

// validateHTTPRequest - بررسی اعتبار request
func (s *Server) validateHTTPRequest(r *http.Request) (isValid bool, reason string) {
	// 1. بررسی Method
	if r.Method != "POST" && r.Method != "GET" {
		return false, "invalid_method"
	}
	
	// 2. بررسی Host (اگر FakeDomain تنظیم شده)
	if s.Mimic != nil && s.Mimic.FakeDomain != "" {
		host := r.Host
		if host == "" {
			host = r.Header.Get("Host")
		}
		
		// Host باید match کنه یا subdomain باشه
		if host != s.Mimic.FakeDomain && 
		   !strings.HasSuffix(host, "."+s.Mimic.FakeDomain) {
			return false, "invalid_host"
		}
	}
	
	// 3. بررسی User-Agent (باید وجود داشته باشه)
	ua := r.Header.Get("User-Agent")
	if ua == "" {
		return false, "missing_user_agent"
	}
	
	// 4. بررسی Accept-Encoding (browsers معمولاً دارن)
	// این یک soft check است
	
	// 5. بررسی Path (اگه GET است باید مجاز باشه)
	if r.Method == "GET" {
		// GET requests فقط برای decoy paths مجاز هستند
		if s.Mimic != nil && s.Mimic.FakePath != "" {
			if !strings.HasPrefix(r.URL.Path, s.Mimic.FakePath) {
				return false, "invalid_get_path"
			}
		}
	}
	
	return true, "ok"
}

// ============================================================================
// FIX 3: Decoy response با body واقعی‌تر
// ============================================================================

// واقعی‌ترین HTML response برای decoy
var realisticHTMLTemplates = []string{
	// Template 1: Search results
	`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Search Results</title>
    <style>body{font-family:Arial,sans-serif;margin:20px}</style>
</head>
<body>
    <h1>Search</h1>
    <div>About 1,234,567 results (0.42 seconds)</div>
    <div style="margin-top:20px">
        <h3>Top results</h3>
        <p>Your search returned several results. Please refine your query.</p>
    </div>
</body>
</html>`,

	// Template 2: API response (JSON-like)
	`{
  "status": "ok",
  "timestamp": %d,
  "data": {
    "items": [],
    "total": 0,
    "page": 1
  }
}`,

	// Template 3: Generic page
	`<!DOCTYPE html>
<html>
<head>
    <title>Page</title>
    <meta charset="utf-8">
</head>
<body>
    <h1>Welcome</h1>
    <p>Content loading...</p>
    <script>setTimeout(function(){location.reload()},5000)</script>
</body>
</html>`,
}

// generateRealisticDecoyBody - تولید body واقعی برای decoy response
func generateRealisticDecoyBody(requestPath string) []byte {
	// انتخاب template بر اساس path
	templateIndex := 0
	
	if strings.Contains(requestPath, "api") || strings.Contains(requestPath, "json") {
		templateIndex = 1 // JSON response
	} else if strings.Contains(requestPath, "search") {
		templateIndex = 0 // Search results
	} else {
		templateIndex = 2 // Generic page
	}
	
	template := realisticHTMLTemplates[templateIndex]
	
	// اگه JSON template است، timestamp رو جایگزین کن
	if templateIndex == 1 {
		template = fmt.Sprintf(template, time.Now().Unix())
	}
	
	return []byte(template)
}

// ============================================================================
// FIX 3 & 6: writeDecoyHTTP200 بهبود یافته با validation
// ============================================================================

func (s *Server) writeDecoyHTTP200_FIXED(w http.ResponseWriter, r *http.Request) {
	// ✅ FIX: Headers واقعی‌تر مثل nginx
	w.Header().Set("Server", "nginx/1.18.0")
	w.Header().Set("Date", time.Now().UTC().Format(http.TimeFormat))
	
	// Content-Type بر اساس request
	contentType := "text/html; charset=utf-8"
	if strings.Contains(r.URL.Path, "api") || strings.Contains(r.URL.Path, "json") {
		contentType = "application/json; charset=utf-8"
	}
	w.Header().Set("Content-Type", contentType)
	
	// ✅ FIX 5: Session Cookie با rotation واقعی
	if s.Mimic != nil && s.Mimic.SessionCookie {
		// تولید session ID جدید (واقعی)
		sessionID := generateRandomSessionID()
		
		http.SetCookie(w, &http.Cookie{
			Name:     "session",
			Value:    sessionID,
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
			MaxAge:   3600, // 1 hour
		})
		
		// اضافه کردن cookies اضافی برای واقعی‌تر بودن (30% احتمال)
		if randInt(10) < 3 {
			http.SetCookie(w, &http.Cookie{
				Name:   "_ga",
				Value:  fmt.Sprintf("GA1.2.%d.%d", randInt(999999999), time.Now().Unix()),
				Path:   "/",
				MaxAge: 86400 * 365 * 2, // 2 years
			})
		}
	}
	
	// Connection header
	w.Header().Set("Connection", "keep-alive")
	
	// Cache headers
	w.Header().Set("Cache-Control", "private, max-age=0, no-cache")
	w.Header().Set("Expires", "-1")
	w.Header().Set("Pragma", "no-cache")
	
	// Security headers (واقعی‌تر)
	w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-XSS-Protection", "1; mode=block")
	w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
	
	// Vary header
	w.Header().Set("Vary", "Accept-Encoding")
	
	// ✅ FIX 3: Body واقعی
	body := generateRealisticDecoyBody(r.URL.Path)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	
	w.WriteHeader(http.StatusOK)
	w.Write(body)
	
	// Log برای debugging
	if s.Verbose {
		log.Printf("[DECOY] %s %s from %s (body: %d bytes)", 
			r.Method, r.URL.Path, r.RemoteAddr, len(body))
	}
}

// ============================================================================
// FIX: HandleHTTP کامل با همه validations
// ============================================================================

func (s *Server) HandleHTTP_FIXED(w http.ResponseWriter, r *http.Request) {
	// ✅ FIX 6: Validate request
	if isValid, reason := s.validateHTTPRequest(r); !isValid {
		if s.Verbose {
			log.Printf("[REJECT] %s %s from %s: %s", 
				r.Method, r.URL.Path, r.RemoteAddr, reason)
		}
		s.writeDecoyHTTP200_FIXED(w, r)
		return
	}
	
	// بررسی path
	expectedPath := "/tunnel"
	if s.Mimic != nil && s.Mimic.FakePath != "" {
		expectedPath = s.Mimic.FakePath
	}
	
	// اگه path درست نیست → decoy
	if r.URL.Path != expectedPath {
		if s.Verbose {
			log.Printf("[DECOY] Wrong path: %s (expected: %s)", r.URL.Path, expectedPath)
		}
		s.writeDecoyHTTP200_FIXED(w, r)
		return
	}
	
	// اگه GET است → decoy
	if r.Method == "GET" {
		if s.Verbose {
			log.Printf("[DECOY] GET request on tunnel path")
		}
		s.writeDecoyHTTP200_FIXED(w, r)
		return
	}
	
	// خواندن body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read failed", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()
	
	// Decrypt
	plain, err := s.Obfs.DecryptPSK(body, s.PSK)
	if err != nil {
		if s.Verbose {
			log.Printf("[DECRYPT_FAIL] from %s", r.RemoteAddr)
		}
		s.writeDecoyHTTP200_FIXED(w, r)
		return
	}
	
	// ✅ FIX 2: Strip fake headers اگه وجود داره
	plain = stripFakeHeaders(plain)
	
	// Parse frame
	reader := bytes.NewReader(plain)
	frame, err := ReadFrame(reader)
	if err != nil {
		if s.Verbose {
			log.Printf("[FRAME_ERROR] from %s: %v", r.RemoteAddr, err)
		}
		s.writeDecoyHTTP200_FIXED(w, r)
		return
	}
	
	// ✅ Extract session from cookie
	sessionID := extractSessionID(r)
	if sessionID == "" && s.Mimic != nil && s.Mimic.SessionCookie {
		sessionID = generateRandomSessionID()
	}
	
	// Process frame
	// ... existing frame processing logic ...
	
	// Response
	w.Header().Set("Server", "nginx/1.18.0")
	w.Header().Set("Content-Type", "application/octet-stream")
	
	// ✅ Set session cookie در response
	if sessionID != "" && s.Mimic != nil && s.Mimic.SessionCookie {
		http.SetCookie(w, &http.Cookie{
			Name:     "session",
			Value:    sessionID,
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
	}
	
	w.WriteHeader(http.StatusOK)
	// ... write response ...
}

// ============================================================================
// Helper functions
// ============================================================================

func generateRandomSessionID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func randInt(n int) int {
	if n <= 0 {
		return 0
	}
	b := make([]byte, 1)
	rand.Read(b)
	return int(b[0]) % n
}

func extractSessionID(r *http.Request) string {
	cookie, err := r.Cookie("session")
	if err != nil {
		return ""
	}
	return cookie.Value
}
