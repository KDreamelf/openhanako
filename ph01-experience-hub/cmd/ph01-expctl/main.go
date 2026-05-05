package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"ph01-experience-hub/internal/hub"
)

type client struct {
	base  string
	token string
	http  *http.Client
}

func main() {
	base := getenv("PH01_EXP_BASE_URL", "http://localhost:8090")
	token := os.Getenv("PH01_EXP_TOKEN")

	fs := flag.NewFlagSet("ph01-expctl", flag.ExitOnError)
	fs.StringVar(&base, "base", base, "experience-hub base URL")
	fs.StringVar(&token, "token", token, "admin token")
	_ = fs.Parse(os.Args[1:])
	args := fs.Args()
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	c := client{
		base:  strings.TrimRight(base, "/"),
		token: token,
		http:  http.DefaultClient,
	}

	var err error
	switch args[0] {
	case "pack":
		err = cmdPack(args[1:])
	case "upload":
		err = c.cmdUpload(args[1:])
	case "list":
		err = c.cmdList(args[1:])
	case "show":
		err = c.cmdShow(args[1:])
	case "read":
		err = c.cmdRead(args[1:])
	case "search":
		err = c.cmdSearch(args[1:])
	case "review":
		err = c.cmdReview(args[1:])
	case "vfs":
		err = c.cmdVFS(args[1:])
	case "fetch":
		err = c.cmdFetch(args[1:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `ph01-expctl [-base URL] [-token TOKEN] <command>

Commands:
  pack [-publisher publisher.json] [-ratings ratings.dat] <raw-dump-dir> <out.hxp>
  upload [-status inbox] <dir-or-hxp>
  list [-status inbox|network|rejected] [-keyword kw] [-q text]
  show <experience_id>
  read <experience_id> [path]        # 默认读取原始转储入口
  search [-status inbox|network|rejected] [-limit n] <text>
  review -status approved|rejected|inbox [-reason text] <experience_id>
  vfs
  fetch <experience_id> <out.hxp>

Environment:
  PH01_EXP_BASE_URL
  PH01_EXP_TOKEN`)
}

func cmdPack(args []string) error {
	fs := flag.NewFlagSet("pack", flag.ExitOnError)
	publisherPath := fs.String("publisher", "", "publisher.json path")
	ratingsPath := fs.String("ratings", "", "ratings.dat path")
	_ = fs.Parse(args)
	if fs.NArg() != 2 {
		return fmt.Errorf("usage: pack [-publisher publisher.json] [-ratings ratings.dat] <raw-dump-dir> <out.hxp>")
	}
	publisherJSON, err := optionalFile(*publisherPath)
	if err != nil {
		return err
	}
	ratingsData, err := optionalFile(*ratingsPath)
	if err != nil {
		return err
	}
	data, err := hub.PackExperiencePackage(fs.Arg(0), publisherJSON, ratingsData)
	if err != nil {
		return err
	}
	return os.WriteFile(fs.Arg(1), data, 0o644)
}

func (c client) cmdUpload(args []string) error {
	fs := flag.NewFlagSet("upload", flag.ExitOnError)
	status := fs.String("status", hub.StatusInbox, "initial status")
	_ = fs.Parse(args)
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: upload [-status inbox] <dir-or-hxp>")
	}
	path := fs.Arg(0)
	data, err := packageInput(path)
	if err != nil {
		return err
	}
	resp, err := c.request(http.MethodPost, "/api/v1/experiences?status="+*status, bytes.NewReader(data), "application/zip")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdList(args []string) error {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	status := fs.String("status", "", "status filter")
	keyword := fs.String("keyword", "", "keyword filter")
	q := fs.String("q", "", "text query")
	_ = fs.Parse(args)
	path := "/api/v1/experiences?" + query(map[string]string{
		"status":  *status,
		"keyword": *keyword,
		"q":       *q,
	})
	resp, err := c.request(http.MethodGet, path, nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdShow(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: show <experience_id>")
	}
	resp, err := c.request(http.MethodGet, "/api/v1/experiences/"+args[0], nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdRead(args []string) error {
	if len(args) < 1 || len(args) > 2 {
		return fmt.Errorf("usage: read <experience_id> [path]")
	}
	rel := ""
	if len(args) == 2 {
		rel = args[1]
	}
	resp, err := c.request(http.MethodGet, "/api/v1/experiences/"+args[0]+"/file?path="+urlQueryEscape(rel), nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdSearch(args []string) error {
	fs := flag.NewFlagSet("search", flag.ExitOnError)
	status := fs.String("status", "", "status filter")
	limit := fs.Int("limit", 50, "max result count")
	_ = fs.Parse(args)
	q := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if q == "" {
		return fmt.Errorf("usage: search [-status inbox|network|rejected] [-limit n] <text>")
	}
	path := "/api/v1/search?" + query(map[string]string{
		"status": *status,
		"q":      q,
		"limit":  fmt.Sprintf("%d", *limit),
	})
	resp, err := c.request(http.MethodGet, path, nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdReview(args []string) error {
	fs := flag.NewFlagSet("review", flag.ExitOnError)
	status := fs.String("status", "", "approved|rejected|inbox")
	reason := fs.String("reason", "", "review reason")
	_ = fs.Parse(args)
	if fs.NArg() != 1 || *status == "" {
		return fmt.Errorf("usage: review -status approved|rejected|inbox [-reason text] <experience_id>")
	}
	body, _ := json.Marshal(hub.ReviewRequest{Status: normalizeReviewStatus(*status), Reason: *reason})
	resp, err := c.request(http.MethodPost, "/api/v1/experiences/"+fs.Arg(0)+"/review", bytes.NewReader(body), "application/json")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdVFS(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("usage: vfs")
	}
	resp, err := c.request(http.MethodGet, "/api/v1/vfs/index", nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, resp.Body)
	return err
}

func (c client) cmdFetch(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: fetch <experience_id> <out.hxp>")
	}
	resp, err := c.request(http.MethodGet, "/api/v1/experiences/"+args[0]+"/package", nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := checkResponse(resp); err != nil {
		return err
	}
	out, err := os.Create(args[1])
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, resp.Body)
	return err
}

func (c client) request(method, path string, body io.Reader, contentType string) (*http.Response, error) {
	req, err := http.NewRequest(method, c.base+path, body)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return c.http.Do(req)
}

func checkResponse(resp *http.Response) error {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	data, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(data)))
}

func packageInput(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.IsDir() {
		return hub.PackExperiencePackage(path, nil, nil)
	}
	return os.ReadFile(path)
}

func optionalFile(path string) ([]byte, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	return os.ReadFile(path)
}

func normalizeReviewStatus(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "approved":
		return hub.StatusNetwork
	case "reject", "rejected":
		return hub.StatusRejected
	default:
		return strings.ToLower(strings.TrimSpace(status))
	}
}

func query(values map[string]string) string {
	parts := make([]string, 0, len(values))
	for k, v := range values {
		if v == "" {
			continue
		}
		parts = append(parts, k+"="+urlQueryEscape(v))
	}
	return strings.Join(parts, "&")
}

func urlQueryEscape(s string) string {
	return url.QueryEscape(filepath.ToSlash(s))
}

func getenv(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
