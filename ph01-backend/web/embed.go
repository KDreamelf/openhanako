// Package web 用 //go:embed 把管理后台 HTML 嵌进 Go binary。
//
// auth-gateway 在 /admin-ui/auth.html 提供。
// /admin-ui/ai.html 只服务于旧 Go 版 ai-gateway 原型，不属于当前生产 AI 网关。
package web

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed admin/*.html
var adminFS embed.FS

// AdminFS 返回 web/admin/ 子文件夹的文件系统视图。
func AdminFS() http.FileSystem {
	sub, err := fs.Sub(adminFS, "admin")
	if err != nil {
		panic(err)
	}
	return http.FS(sub)
}
