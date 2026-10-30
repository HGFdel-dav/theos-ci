//
//  DNBLogic.h
//  DebsNewsBatch
//
//  纯 C 逻辑层（零依赖，只用 string.h/stdio.h）：App 内注入代码与 iSH 本地单测编译同一份，
//  保证「被测试的就是被发布的」。
//

#ifndef DNB_LOGIC_H
#define DNB_LOGIC_H

#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* 新闻列表过滤器 */
enum {
    DNB_FILTER_ALL = 0,
    DNB_FILTER_ARM64 = 1,
    DNB_FILTER_ARM64E = 2,
    DNB_FILTER_MISSING = 3   /* 仅未下载 */
};

static inline int dnb_is_space(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/* 去掉首尾空白并复制（永远以 \0 结尾） */
static inline size_t dnb_trim_copy(char *out, size_t cap, const char *in)
{
    if (!out || cap == 0) {
        return 0;
    }
    out[0] = '\0';
    if (!in) {
        return 0;
    }
    while (*in && dnb_is_space(*in)) {
        in++;
    }
    size_t n = strlen(in);
    while (n > 0 && dnb_is_space(in[n - 1])) {
        n--;
    }
    if (n >= cap) {
        n = cap - 1;
    }
    memcpy(out, in, n);
    out[n] = '\0';
    return n;
}

static inline int dnb_has_prefix(const char *s, const char *p)
{
    if (!s || !p) {
        return 0;
    }
    return strncmp(s, p, strlen(p)) == 0;
}

/*
 * 拼接下载地址。
 * - rel 是完整 URL（http/https）时直接采用；
 * - 否则 base 去掉尾部 '/'、rel 去掉头部 '/'，拼成 base + "/" + rel。
 * 返回 1 成功，0 失败（失败时 out 为空串）。
 */
static inline int dnblogic_join_url(char *out, size_t cap, const char *base, const char *rel)
{
    char b[2048];
    char r[2048];

    if (!out || cap == 0) {
        return 0;
    }
    out[0] = '\0';
    dnb_trim_copy(b, sizeof(b), base);
    dnb_trim_copy(r, sizeof(r), rel);
    if (r[0] == '\0') {
        return 0;
    }
    if (dnb_has_prefix(r, "http://") || dnb_has_prefix(r, "https://")) {
        if (strlen(r) + 1 > cap) {
            return 0;
        }
        strcpy(out, r);
        return 1;
    }
    size_t n = strlen(b);
    while (n > 0 && b[n - 1] == '/') {
        b[--n] = '\0';
    }
    if (n == 0) {
        return 0;
    }
    const char *rp = r;
    while (*rp == '/') {
        rp++;
    }
    if (*rp == '\0') {
        return 0;
    }
    int written = snprintf(out, cap, "%s/%s", b, rp);
    if (written <= 0 || (size_t)written >= cap) {
        out[0] = '\0';
        return 0;
    }
    return 1;
}

/* 把单个字段清理成可以放进文件名的片段：去掉路径分隔符、控制字符，并修剪首尾空白 */
static inline size_t dnb_sanitize_token(char *out, size_t cap, const char *in)
{
    if (!out || cap == 0) {
        return 0;
    }
    out[0] = '\0';
    if (!in) {
        return 0;
    }
    size_t j = 0;
    for (const char *p = in; *p && j + 1 < cap; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '/' || c == '\\' || c == ':' || c < 0x20) {
            c = '_';
        }
        out[j++] = (char)c;
    }
    out[j] = '\0';

    /* 原地修剪首尾空白 */
    size_t start = 0;
    while (out[start] && dnb_is_space(out[start])) {
        start++;
    }
    size_t len = strlen(out + start);
    while (len > 0 && dnb_is_space(out[start + len - 1])) {
        len--;
    }
    if (start > 0) {
        memmove(out, out + start, len);
    }
    out[len] = '\0';
    return len;
}

/*
 * 生成保存文件名，规则与 App 自身下载保持一致：<名称>-<版本>-<架构>.deb
 * 名称里的空格保留（与 App 现有文件 "AI 日志分析-1.1.5-iphoneos-arm64.deb" 一致）。
 */
static inline int dnblogic_save_name(char *out, size_t cap,
                                     const char *name, const char *version, const char *arch)
{
    char n[256];
    char v[128];
    char a[128];

    if (!out || cap == 0) {
        return 0;
    }
    out[0] = '\0';
    dnb_sanitize_token(n, sizeof(n), name);
    dnb_sanitize_token(v, sizeof(v), version);
    dnb_sanitize_token(a, sizeof(a), arch);
    if (n[0] == '\0') {
        strcpy(n, "package");
    }

    int written;
    if (v[0] == '\0' && a[0] == '\0') {
        written = snprintf(out, cap, "%s.deb", n);
    } else if (v[0] == '\0') {
        written = snprintf(out, cap, "%s-%s.deb", n, a);
    } else if (a[0] == '\0') {
        written = snprintf(out, cap, "%s-%s.deb", n, v);
    } else {
        written = snprintf(out, cap, "%s-%s-%s.deb", n, v, a);
    }
    if (written <= 0 || (size_t)written >= cap) {
        out[0] = '\0';
        return 0;
    }
    return 1;
}

static inline int dnblogic_arch_is_arm64e(const char *arch)
{
    char t[64];
    dnb_trim_copy(t, sizeof(t), arch);
    return strcmp(t, "iphoneos-arm64e") == 0;
}

static inline int dnblogic_arch_is_arm64(const char *arch)
{
    char t[64];
    dnb_trim_copy(t, sizeof(t), arch);
    return strcmp(t, "iphoneos-arm64") == 0;
}

/* filter 与架构/是否已下载是否匹配（arm64 与 arm64e 必须严格区分，不能前缀匹配） */
static inline int dnblogic_filter_match(int filter, const char *arch, int already_downloaded)
{
    switch (filter) {
        case DNB_FILTER_ARM64:
            return dnblogic_arch_is_arm64(arch);
        case DNB_FILTER_ARM64E:
            return dnblogic_arch_is_arm64e(arch);
        case DNB_FILTER_MISSING:
            return already_downloaded ? 0 : 1;
        case DNB_FILTER_ALL:
        default:
            return 1;
    }
}

/* deb 是 ar 归档，魔术字节 "!<arch>\n"；用它识别源返回的 HTML/错误页 */
static inline int dnblogic_is_deb_magic(const void *buf, size_t len)
{
    static const char magic[8] = { '!', '<', 'a', 'r', 'c', 'h', '>', '\n' };
    if (!buf || len < sizeof(magic)) {
        return 0;
    }
    return memcmp(buf, magic, sizeof(magic)) == 0;
}

static inline void dnblogic_sel_all(unsigned char *sel, size_t n, int value)
{
    if (!sel) {
        return;
    }
    for (size_t i = 0; i < n; i++) {
        sel[i] = value ? 1 : 0;
    }
}

static inline size_t dnblogic_sel_count(const unsigned char *sel, size_t n)
{
    size_t c = 0;
    if (!sel) {
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        if (sel[i]) {
            c++;
        }
    }
    return c;
}

static inline void dnblogic_sel_toggle(unsigned char *sel, size_t n, size_t idx)
{
    if (!sel || idx >= n) {
        return;
    }
    sel[idx] = sel[idx] ? 0 : 1;
}

/* 同名文件已存在时：只有开启「覆盖」才写 */
static inline int dnblogic_should_write(int file_exists, int overwrite)
{
    if (!file_exists) {
        return 1;
    }
    return overwrite ? 1 : 0;
}

static inline int dnblogic_percent(size_t done, size_t total)
{
    if (total == 0) {
        return 0;
    }
    if (done >= total) {
        return 100;
    }
    return (int)((done * 100) / total);
}

/* ------------------------------------------------------------------
 * 新闻行标签解析
 *
 * App 的新闻行是一条可访问元素，标签形如：
 *   "Apelin, 更新, 0.3.0, iphoneos-arm64e, mowang"
 *   "电话助手iOS16-正式版-Roothide, 更新, 3.3.1, iphoneos-arm64e, Ai-小苹果™"
 * 名称本身可能含 ", "，所以从右往左找「架构」「版本」「变更标签」，剩下的才是名称。
 * 日期分组头（"2026年10月30日"）不是行，直接排除。
 * ------------------------------------------------------------------ */

#define DNB_ROW_NAME_MAX 192
#define DNB_ROW_VER_MAX 48
#define DNB_ROW_ARCH_MAX 32

typedef struct {
    char name[DNB_ROW_NAME_MAX];
    char version[DNB_ROW_VER_MAX];
    char arch[DNB_ROW_ARCH_MAX];
    char key[DNB_ROW_NAME_MAX + DNB_ROW_VER_MAX + DNB_ROW_ARCH_MAX + 8];
} dnb_row_label;

enum { DNB_ROW_NOT_NEWS = 0, DNB_ROW_IS_NEWS = 1 };

static inline int dnb_is_arch_token(const char *t)
{
    return dnb_has_prefix(t, "iphoneos-") || dnb_has_prefix(t, "appletvos-")
        || dnb_has_prefix(t, "watchos-") || dnb_has_prefix(t, "tvos-")
        || dnb_has_prefix(t, "darwin-");
}

static inline int dnb_is_change_tag(const char *t)
{
    return strcmp(t, "更新") == 0 || strcmp(t, "新上架") == 0 || strcmp(t, "重传") == 0
        || strcmp(t, "降级") == 0 || strcmp(t, "移除") == 0 || strcmp(t, "新增") == 0
        || strcmp(t, "上架") == 0;
}

/* 版本号：只允许数字与 . + - ~ : _ ( ) # 以及非 ASCII 后缀（如 r1 / 中文） */
static inline int dnb_is_version_token(const char *t)
{
    int digits = 0;
    size_t n = strlen(t);
    if (n == 0 || n > 24) {
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)t[i];
        if (c >= '0' && c <= '9') {
            digits++;
            continue;
        }
        if (c == '.' || c == '+' || c == '-' || c == '~' || c == ':' || c == '_'
            || c == '(' || c == ')' || c == '#') {
            continue;
        }
        if (c >= 0x80) {
            continue;
        }
        return 0;
    }
    return digits > 0;
}

static inline int dnb_parse_row_label(const char *label, dnb_row_label *out)
{
    char buf[512];
    char *tok[16];
    int n = 0;

    if (!out) {
        return 0;
    }
    memset(out, 0, sizeof(*out));
    if (!label) {
        return 0;
    }
    dnb_trim_copy(buf, sizeof(buf), label);
    if (buf[0] == '\0') {
        return 0;
    }
    /* 日期分组头 */
    if (strstr(buf, "年") && strstr(buf, "月") && strstr(buf, "日")) {
        return 0;
    }

    char *p = buf;
    while (p && *p && n < 16) {
        tok[n++] = p;
        char *comma = strstr(p, ", ");
        if (!comma) {
            break;
        }
        *comma = '\0';
        p = comma + 2;
    }
    if (n < 3) {
        return 0;
    }

    int archIdx = -1;
    for (int i = n - 1; i >= 1; i--) {
        if (dnb_is_arch_token(tok[i])) {
            archIdx = i;
            break;
        }
    }
    if (archIdx < 2) {
        return 0;
    }
    int verIdx = archIdx - 1;
    if (!dnb_is_version_token(tok[verIdx])) {
        return 0;
    }
    int nameEnd = verIdx;
    if (nameEnd >= 1 && dnb_is_change_tag(tok[nameEnd - 1])) {
        nameEnd--;
    }
    if (nameEnd < 1) {
        return 0;
    }
    size_t off = 0;
    for (int i = 0; i < nameEnd; i++) {
        size_t len = strlen(tok[i]);
        if (off + len + 3 >= sizeof(out->name)) {
            return 0;
        }
        if (i > 0) {
            out->name[off++] = ',';
            out->name[off++] = ' ';
        }
        memcpy(out->name + off, tok[i], len);
        off += len;
    }
    out->name[off] = '\0';
    dnb_trim_copy(out->version, sizeof(out->version), tok[verIdx]);
    dnb_trim_copy(out->arch, sizeof(out->arch), tok[archIdx]);
    if (out->name[0] == '\0' || out->version[0] == '\0' || out->arch[0] == '\0') {
        return 0;
    }
    snprintf(out->key, sizeof(out->key), "%s\t%s\t%s", out->name, out->version, out->arch);
    return DNB_ROW_IS_NEWS;
}

/* 行标签与条目字段是否指同一条 */
static inline int dnblogic_row_matches(const dnb_row_label *row, const char *name,
                                       const char *version, const char *arch)
{
    char n[DNB_ROW_NAME_MAX];
    char v[DNB_ROW_VER_MAX];
    char a[DNB_ROW_ARCH_MAX];
    if (!row) {
        return 0;
    }
    dnb_trim_copy(n, sizeof(n), name);
    dnb_trim_copy(v, sizeof(v), version);
    dnb_trim_copy(a, sizeof(a), arch);
    return strcmp(row->name, n) == 0 && strcmp(row->version, v) == 0 && strcmp(row->arch, a) == 0;
}

#endif /* DNB_LOGIC_H */
