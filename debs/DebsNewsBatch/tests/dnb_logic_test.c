/*
 * DebsNewsBatch 本地纯 C 单测：直接编译 Tweak 使用的 DNBLogic.h，
 * 在 iSH 上运行，验证地址拼接、文件名生成、过滤器、deb 魔术字节、选择集合等逻辑。
 * 编译：cc -Wall -Wextra -Werror -I../DebsNewsBatch dnb_logic_test.c -o /tmp/dnb_logic_test
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "DNBLogic.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond) do { \
    if (cond) { g_pass++; } \
    else { g_fail++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
} while (0)

#define CHECK_STR(actual, expect) do { \
    if (strcmp((actual), (expect)) == 0) { g_pass++; } \
    else { g_fail++; printf("FAIL %s:%d  得到 \"%s\" 期望 \"%s\"\n", __FILE__, __LINE__, (actual), (expect)); } \
} while (0)

static void test_join_url(void)
{
    char out[512];

    CHECK(dnblogic_join_url(out, sizeof(out), "https://axs.yourepo.com/", "debs/sbcpufloating_1.0_iphoneos-arm64.deb") == 1);
    CHECK_STR(out, "https://axs.yourepo.com/debs/sbcpufloating_1.0_iphoneos-arm64.deb");

    CHECK(dnblogic_join_url(out, sizeof(out), "https://yzdmm2024.github.io/repo", "/debs/com.ntm.notifymanager_2.3.11_iphoneos-arm64.deb") == 1);
    CHECK_STR(out, "https://yzdmm2024.github.io/repo/debs/com.ntm.notifymanager_2.3.11_iphoneos-arm64.deb");

    CHECK(dnblogic_join_url(out, sizeof(out), "  https://a.example///  ", "///debs/x.deb") == 1);
    CHECK_STR(out, "https://a.example/debs/x.deb");

    CHECK(dnblogic_join_url(out, sizeof(out), "https://a.example", "https://cdn.example/f.deb") == 1);
    CHECK_STR(out, "https://cdn.example/f.deb");

    CHECK(dnblogic_join_url(out, sizeof(out), "https://a.example", "http://cdn.example/f.deb") == 1);
    CHECK_STR(out, "http://cdn.example/f.deb");

    /* 失败分支 */
    CHECK(dnblogic_join_url(out, sizeof(out), "https://a.example", "") == 0);
    CHECK_STR(out, "");
    CHECK(dnblogic_join_url(out, sizeof(out), "", "debs/x.deb") == 0);
    CHECK_STR(out, "");
    CHECK(dnblogic_join_url(out, sizeof(out), "   ", "debs/x.deb") == 0);
    CHECK_STR(out, "");
    CHECK(dnblogic_join_url(out, sizeof(out), "https://a.example", "///") == 0);
    CHECK_STR(out, "");
    CHECK(dnblogic_join_url(out, sizeof(out), NULL, "debs/x.deb") == 0);
    CHECK(dnblogic_join_url(NULL, 0, "https://a.example", "debs/x.deb") == 0);
    /* 缓冲区太小必须失败且不留半截 */
    char small[16];
    CHECK(dnblogic_join_url(small, sizeof(small), "https://a.example", "debs/x.deb") == 0);
    CHECK_STR(small, "");
    CHECK(dnblogic_join_url(small, sizeof(small), "https://cdn.example", "http://cdn.example/f.deb") == 0);
    CHECK_STR(small, "");
}

static void test_save_name(void)
{
    char out[512];

    CHECK(dnblogic_save_name(out, sizeof(out), "通知管理", "2.3.11", "iphoneos-arm64") == 1);
    CHECK_STR(out, "通知管理-2.3.11-iphoneos-arm64.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "AI 日志分析", "1.1.5", "iphoneos-arm64") == 1);
    CHECK_STR(out, "AI 日志分析-1.1.5-iphoneos-arm64.deb");

    /* 路径分隔符与控制字符必须被清理，避免写到别的目录 */
    CHECK(dnblogic_save_name(out, sizeof(out), "../evil/x", "1.0", "iphoneos-arm64e") == 1);
    CHECK(strstr(out, "/") == NULL);
    CHECK_STR(out, ".._evil_x-1.0-iphoneos-arm64e.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "a:b\\c", "1.0", "iphoneos-arm64") == 1);
    CHECK_STR(out, "a_b_c-1.0-iphoneos-arm64.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "  名称  ", " 1.0 ", " iphoneos-arm64 ") == 1);
    CHECK_STR(out, "名称-1.0-iphoneos-arm64.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "OnlyName", "", "") == 1);
    CHECK_STR(out, "OnlyName.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "", "1.0", "") == 1);
    CHECK_STR(out, "package-1.0.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "", "", "") == 1);
    CHECK_STR(out, "package.deb");

    CHECK(dnblogic_save_name(out, sizeof(out), "Name", "", "iphoneos-arm64e") == 1);
    CHECK_STR(out, "Name-iphoneos-arm64e.deb");

    char small[12];
    CHECK(dnblogic_save_name(small, sizeof(small), "非常长的名字非常长的名字", "1.0", "iphoneos-arm64") == 0);
    CHECK_STR(small, "");
    CHECK(dnblogic_save_name(NULL, 0, "a", "b", "c") == 0);
}

static void test_filter(void)
{
    CHECK(dnblogic_filter_match(DNB_FILTER_ALL, "iphoneos-arm64", 0) == 1);
    CHECK(dnblogic_filter_match(DNB_FILTER_ALL, "iphoneos-arm64e", 1) == 1);
    CHECK(dnblogic_filter_match(DNB_FILTER_ALL, "", 0) == 1);

    CHECK(dnblogic_filter_match(DNB_FILTER_ARM64, "iphoneos-arm64", 0) == 1);
    CHECK(dnblogic_filter_match(DNB_FILTER_ARM64, "iphoneos-arm64e", 0) == 0); /* 严格区分 */
    CHECK(dnblogic_filter_match(DNB_FILTER_ARM64, " iphoneos-arm64 ", 0) == 1);
    CHECK(dnblogic_filter_match(DNB_FILTER_ARM64, "iphoneos-arm", 0) == 0);

    CHECK(dnblogic_filter_match(DNB_FILTER_ARM64E, "iphoneos-arm64e", 0) == 1);
    CHECK(dnblogic_filter_match(DNB_FILTER_ARM64E, "iphoneos-arm64", 0) == 0);

    CHECK(dnblogic_filter_match(DNB_FILTER_MISSING, "iphoneos-arm64", 0) == 1);
    CHECK(dnblogic_filter_match(DNB_FILTER_MISSING, "iphoneos-arm64", 1) == 0);

    CHECK(dnblogic_arch_is_arm64("iphoneos-arm64") == 1);
    CHECK(dnblogic_arch_is_arm64("iphoneos-arm64e") == 0);
    CHECK(dnblogic_arch_is_arm64e("iphoneos-arm64e") == 1);
    CHECK(dnblogic_arch_is_arm64e("iphoneos-arm64") == 0);
}

static void test_deb_magic(void)
{
    const char *good = "!<arch>\ndebian-binary";
    const char *html = "<!DOCTYPE html>\n<html>";
    char shortbuf[4] = { '!', '<', 'a' };

    CHECK(dnblogic_is_deb_magic(good, strlen(good)) == 1);
    CHECK(dnblogic_is_deb_magic(html, strlen(html)) == 0);
    CHECK(dnblogic_is_deb_magic(shortbuf, sizeof(shortbuf)) == 0);
    CHECK(dnblogic_is_deb_magic(NULL, 100) == 0);
    CHECK(dnblogic_is_deb_magic(good, 8) == 1);
}

static void test_selection(void)
{
    unsigned char sel[8];
    memset(sel, 0xAA, sizeof(sel));

    dnblogic_sel_all(sel, 8, 1);
    CHECK(dnblogic_sel_count(sel, 8) == 8);
    dnblogic_sel_toggle(sel, 8, 0);
    dnblogic_sel_toggle(sel, 8, 7);
    CHECK(dnblogic_sel_count(sel, 8) == 6);
    CHECK(sel[0] == 0 && sel[7] == 0 && sel[1] == 1);
    dnblogic_sel_toggle(sel, 8, 7);
    CHECK(sel[7] == 1);
    dnblogic_sel_toggle(sel, 8, 99);      /* 越界不得改动 */
    CHECK(dnblogic_sel_count(sel, 8) == 7);
    dnblogic_sel_all(sel, 8, 0);
    CHECK(dnblogic_sel_count(sel, 8) == 0);
    dnblogic_sel_toggle(NULL, 8, 0);      /* 空指针安全 */
    dnblogic_sel_all(NULL, 8, 1);
    CHECK(dnblogic_sel_count(NULL, 8) == 0);
    CHECK(dnblogic_sel_count(sel, 0) == 0);
}

static void test_write_and_percent(void)
{
    CHECK(dnblogic_should_write(0, 0) == 1);
    CHECK(dnblogic_should_write(0, 1) == 1);
    CHECK(dnblogic_should_write(1, 0) == 0);
    CHECK(dnblogic_should_write(1, 1) == 1);

    CHECK(dnblogic_percent(0, 0) == 0);
    CHECK(dnblogic_percent(0, 4) == 0);
    CHECK(dnblogic_percent(1, 4) == 25);
    CHECK(dnblogic_percent(3, 4) == 75);
    CHECK(dnblogic_percent(4, 4) == 100);
    CHECK(dnblogic_percent(9, 4) == 100);
}

static void test_trim(void)
{
    char out[64];
    CHECK(dnb_trim_copy(out, sizeof(out), "  hi  ") == 2);
    CHECK_STR(out, "hi");
    CHECK(dnb_trim_copy(out, sizeof(out), "") == 0);
    CHECK_STR(out, "");
    CHECK(dnb_trim_copy(out, sizeof(out), NULL) == 0);
    CHECK_STR(out, "");
    CHECK(dnb_trim_copy(out, 3, "abcdef") == 2);
    CHECK_STR(out, "ab");
    CHECK(dnb_has_prefix("https://a", "https://") == 1);
    CHECK(dnb_has_prefix("http://a", "https://") == 0);
}

/* 新闻行标签解析：正常行 / 名称带逗号 / 变更标签 / 日期头 / 各种非行文本 */
static void test_row_label(void)
{
    dnb_row_label r;

    CHECK(dnb_parse_row_label("Apelin, 更新, 0.3.0, iphoneos-arm64e, mowang", &r) == DNB_ROW_IS_NEWS);
    CHECK_STR(r.name, "Apelin");
    CHECK_STR(r.version, "0.3.0");
    CHECK_STR(r.arch, "iphoneos-arm64e");
    CHECK_STR(r.key, "Apelin\t0.3.0\tiphoneos-arm64e");

    CHECK(dnb_parse_row_label("电话助手iOS16-正式版-Roothide, 更新, 3.3.1, iphoneos-arm64e, Ai-小苹果™", &r) == DNB_ROW_IS_NEWS);
    CHECK_STR(r.name, "电话助手iOS16-正式版-Roothide");
    CHECK_STR(r.arch, "iphoneos-arm64e");

    CHECK(dnb_parse_row_label("QQ图文同发, 新上架, 1.0.6, iphoneos-arm64, mowang", &r) == DNB_ROW_IS_NEWS);
    CHECK_STR(r.name, "QQ图文同发");
    CHECK_STR(r.version, "1.0.6");

    /* 名称里含 ", " 要保留 */
    CHECK(dnb_parse_row_label("A, B, 更新, 2.1.0, iphoneos-arm64, src", &r) == DNB_ROW_IS_NEWS);
    CHECK_STR(r.name, "A, B");
    CHECK_STR(r.version, "2.1.0");

    /* 没有变更标签也能解析 */
    CHECK(dnb_parse_row_label("iFetch, 6.0.0, iphoneos-arm64, Huayuarc", &r) == DNB_ROW_IS_NEWS);
    CHECK_STR(r.name, "iFetch");
    CHECK_STR(r.version, "6.0.0");

    /* appletvos 也算行 */
    CHECK(dnb_parse_row_label("Irisin, 更新, 5.1.1, appletvos-arm64e, Huayuarc", &r) == DNB_ROW_IS_NEWS);
    CHECK_STR(r.arch, "appletvos-arm64e");

    /* 日期分组头 */
    CHECK(dnb_parse_row_label("2026年10月30日", &r) == DNB_ROW_NOT_NEWS);
    CHECK(dnb_parse_row_label("2026年10月30日, 3 项", &r) == DNB_ROW_NOT_NEWS);

    /* 各种非行 */
    CHECK(dnb_parse_row_label(NULL, &r) == DNB_ROW_NOT_NEWS);
    CHECK(dnb_parse_row_label("", &r) == DNB_ROW_NOT_NEWS);
    CHECK(dnb_parse_row_label("新闻", &r) == DNB_ROW_NOT_NEWS);
    CHECK(dnb_parse_row_label("Apelin, 更新, 0.3.0", &r) == DNB_ROW_NOT_NEWS);        /* 没架构 */
    CHECK(dnb_parse_row_label("Apelin, 更新, iphoneos-arm64e", &r) == DNB_ROW_NOT_NEWS); /* 没版本 */
    CHECK(dnb_parse_row_label("iphoneos-arm64e, 0.3.0", &r) == DNB_ROW_NOT_NEWS);    /* 没名称 */
    CHECK(dnb_parse_row_label("Apelin, 更新, 版本不详, iphoneos-arm64, s", &r) == DNB_ROW_NOT_NEWS);
    CHECK(dnb_parse_row_label("Apelin, 更新, 0.3.0, iphoneos-arm64, s", NULL) == DNB_ROW_NOT_NEWS);

    /* 匹配 */
    CHECK(dnb_parse_row_label("Apelin, 更新, 0.3.0, iphoneos-arm64e, mowang", &r) == DNB_ROW_IS_NEWS);
    CHECK(dnblogic_row_matches(&r, "Apelin", "0.3.0", "iphoneos-arm64e") == 1);
    CHECK(dnblogic_row_matches(&r, "Apelin ", "0.3.0", "iphoneos-arm64e ") == 1);
    CHECK(dnblogic_row_matches(&r, "Apelin", "0.3.0", "iphoneos-arm64") == 0);
    CHECK(dnblogic_row_matches(&r, "Apelin", "0.3.1", "iphoneos-arm64e") == 0);
    CHECK(dnblogic_row_matches(&r, "ApelinX", "0.3.0", "iphoneos-arm64e") == 0);
}

int main(void)
{
    test_join_url();
    test_save_name();
    test_filter();
    test_deb_magic();
    test_selection();
    test_write_and_percent();
    test_trim();
    test_row_label();

    printf("DNBLogic 单测：通过 %d 项，失败 %d 项\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
