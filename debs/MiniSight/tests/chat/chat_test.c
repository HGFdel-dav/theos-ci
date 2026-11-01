// Pure C regression test for tools/chat/ChatCore.c. No iOS SDK, no Foundation.
// build: cc -std=c11 -Wall -Wextra -Werror -O1 -o /tmp/chat_test tests/chat/chat_test.c tools/chat/ChatCore.c
#define _POSIX_C_SOURCE 200809L
#include "../../tools/chat/ChatCore.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; assert(x); } while (0)

static MSChatValue *string(const char *s) {
    MSChatValue *v = MSChatValueNewString(s);
    assert(v);
    return v;
}
static MSChatValue *array(void) {
    MSChatValue *v = MSChatValueNewArray(2);
    assert(v);
    return v;
}
static MSChatValue *dict(void) {
    MSChatValue *v = MSChatValueNewDict(2);
    assert(v);
    return v;
}
static void set(MSChatValue *d, const char *k, MSChatValue *v) {
    CHECK(MSChatDictSet(d, k, v));
}
static void push(MSChatValue *a, MSChatValue *v) {
    CHECK(MSChatArrayAppend(a, v));
}

static void test_endpoint(void) {
    char out[MSCHAT_ENDPOINT_MAX];

    CHECK(MSChatBuildEndpoint("https://api.example.com/", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://api.example.com/v1/chat/completions") == 0);
    CHECK(MSChatBuildEndpoint("  https://api.example.com  ", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://api.example.com/v1/chat/completions") == 0);

    CHECK(MSChatBuildEndpoint("https://gw.example.com/openai/v1", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://gw.example.com/openai/v1/chat/completions") == 0);
    CHECK(MSChatBuildEndpoint("https://gw.example.com/openai/v1/", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://gw.example.com/openai/v1/chat/completions") == 0);

    CHECK(MSChatBuildEndpoint("https://gw.example.com/v1/chat/completions", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://gw.example.com/v1/chat/completions") == 0);
    CHECK(MSChatBuildEndpoint("https://gw.example.com/v1/chat/completions/", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://gw.example.com/v1/chat/completions") == 0);

    CHECK(MSChatBuildEndpoint("https://gw.example.com?api-version=2", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://gw.example.com/v1/chat/completions?api-version=2") == 0);
    CHECK(MSChatBuildEndpoint("https://gw.example.com/base/?x=1", out, sizeof out) == MSChatURLOK);
    CHECK(strcmp(out, "https://gw.example.com/base/chat/completions?x=1") == 0);

    CHECK(MSChatBuildEndpoint("ftp://gw.example.com", out, sizeof out) == MSChatURLBadScheme);
    CHECK(MSChatBuildEndpoint("gw.example.com/v1", out, sizeof out) == MSChatURLMalformed);
    CHECK(MSChatBuildEndpoint("https://user:pass@gw.example.com", out, sizeof out) == MSChatURLUserInfo);
    CHECK(MSChatBuildEndpoint("https://user@gw.example.com", out, sizeof out) == MSChatURLUserInfo);
    CHECK(MSChatBuildEndpoint("https://gw.example.com/v1#frag", out, sizeof out) == MSChatURLFragment);
    CHECK(MSChatBuildEndpoint("", out, sizeof out) == MSChatURLEmpty);
    CHECK(MSChatBuildEndpoint("   ", out, sizeof out) == MSChatURLEmpty);
    CHECK(MSChatBuildEndpoint("https://", out, sizeof out) == MSChatURLNoHost);
    CHECK(MSChatBuildEndpoint("https:///v1", out, sizeof out) == MSChatURLNoHost);
    CHECK(MSChatBuildEndpoint("https://gw.example.com/a b", out, sizeof out) == MSChatURLBadChars);
    CHECK(MSChatBuildEndpoint("HTTPS://GW.example.com/V1/", out, sizeof out) == MSChatURLOK);
    CHECK(strncmp(out, "https://", 8) == 0);
    CHECK(strcmp(out, "https://GW.example.com/V1/chat/completions") == 0);

    {
        char tiny[24];
        CHECK(MSChatBuildEndpoint("https://gw.example.com/v1", tiny, sizeof tiny) == MSChatURLTooLong);
    }
    {
        char huge[MSCHAT_ENDPOINT_MAX + 2];
        char base[MSCHAT_ENDPOINT_MAX + 2];
        memset(base, 'a', sizeof base - 1);
        base[0] = 'h'; base[1] = 't'; base[2] = 't'; base[3] = 'p';
        base[4] = ':'; base[5] = '/'; base[6] = '/';
        base[sizeof base - 1] = '\0';
        CHECK(MSChatBuildEndpoint(base, huge, sizeof huge) == MSChatURLTooLong);
    }
}

static void test_context(void) {
    MSChatContext ctx;
    char big[1500];
    int i;

    MSChatContextInit(&ctx);
    CHECK(MSChatContextAdd(&ctx, MSChatRoleSystem, "system rule"));
    for (i = 0; i < 20; ++i) {
        char line[32];
        snprintf(line, sizeof line, "turn %d", i);
        CHECK(MSChatContextAdd(&ctx, (i % 2) ? MSChatRoleAssistant : MSChatRoleUser, line));
    }
    CHECK(ctx.count == MSCHAT_MAX_MESSAGES);
    CHECK(ctx.items[0].role == MSChatRoleSystem);
    CHECK(strcmp(ctx.items[0].content, "system rule") == 0);
    CHECK(strcmp(ctx.items[ctx.count - 1].content, "turn 19") == 0);
    CHECK(ctx.chars <= MSCHAT_MAX_CHARS);

    // A late system message still lands in front of the conversation.
    CHECK(MSChatContextAdd(&ctx, MSChatRoleSystem, "late rule"));
    CHECK(ctx.items[0].role == MSChatRoleSystem);
    CHECK(strcmp(ctx.items[0].content, "late rule") == 0);
    CHECK(ctx.count <= MSCHAT_MAX_MESSAGES);

    MSChatContextInit(&ctx);
    CHECK(MSChatContextAdd(&ctx, MSChatRoleSystem, "keep me"));
    memset(big, 'x', sizeof big - 1);
    big[sizeof big - 1] = '\0';
    for (i = 0; i < 10; ++i) CHECK(MSChatContextAdd(&ctx, MSChatRoleUser, big));
    CHECK(ctx.count <= MSCHAT_MAX_MESSAGES);
    CHECK(ctx.chars <= MSCHAT_MAX_CHARS);
    CHECK(ctx.items[0].role == MSChatRoleSystem);
    CHECK(strcmp(ctx.items[0].content, "keep me") == 0);
    CHECK(strlen(ctx.items[ctx.count - 1].content) == sizeof big - 1);

    // The newest turn survives even when older turns already fill the budget.
    MSChatContextInit(&ctx);
    for (i = 0; i < 9; ++i) CHECK(MSChatContextAdd(&ctx, MSChatRoleUser, big));
    CHECK(MSChatContextAdd(&ctx, MSChatRoleUser, "newest"));
    CHECK(ctx.chars <= MSCHAT_MAX_CHARS);
    CHECK(strcmp(ctx.items[ctx.count - 1].content, "newest") == 0);

    MSChatContextInit(&ctx);
    CHECK(!MSChatContextAdd(&ctx, MSChatRoleUser, "   "));
    CHECK(!MSChatContextAdd(&ctx, MSChatRoleUser, NULL));
    CHECK(ctx.count == 0);
    CHECK(strcmp(MSChatRoleName(MSChatRoleSystem), "system") == 0);
    CHECK(strcmp(MSChatRoleName(MSChatRoleUser), "user") == 0);
    CHECK(strcmp(MSChatRoleName(MSChatRoleAssistant), "assistant") == 0);

    // UTF-8 truncation never leaves half a Chinese character.
    MSChatContextInit(&ctx);
    {
        char cjk[MSCHAT_CONTENT_MAX + 200];
        memset(cjk, 0, sizeof cjk);
        for (i = 0; i + 3 < (int)sizeof cjk; i += 3) memcpy(cjk + i, "中", 3);
        CHECK(MSChatContextAdd(&ctx, MSChatRoleUser, cjk));
        CHECK(strlen(ctx.items[0].content) % 3 == 0);
    }
}

static MSChatValue *choicesWithMessage(MSChatValue *content) {
    MSChatValue *root = dict();
    MSChatValue *choices = array();
    MSChatValue *first = dict();
    MSChatValue *message = dict();
    set(message, "role", string("assistant"));
    set(message, "content", content);
    set(first, "message", message);
    push(choices, first);
    set(root, "choices", choices);
    return root;
}

static void test_extract(void) {
    char out[MSCHAT_TEXT_MAX];
    MSChatValue *root;

    root = dict();
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractEmpty);
    MSChatValueFree(root);

    root = dict();
    set(root, "choices", array());
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractEmpty);
    MSChatValueFree(root);

    root = choicesWithMessage(string("  hello  "));
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
    CHECK(strcmp(out, "hello") == 0);
    MSChatValueFree(root);

    {
        MSChatValue *parts = array();
        MSChatValue *p1 = dict();
        MSChatValue *p2 = dict();
        set(p1, "type", string("text"));
        set(p1, "text", string("line a"));
        set(p2, "text", string("line b"));
        push(parts, p1);
        push(parts, p2);
        root = choicesWithMessage(parts);
        CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
        CHECK(strcmp(out, "line a\nline b") == 0);
        MSChatValueFree(root);
    }

    {
        MSChatValue *content = dict();
        MSChatValue *inner = dict();
        set(inner, "text", string("nested"));
        set(content, "content", inner);
        root = choicesWithMessage(content);
        CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
        CHECK(strcmp(out, "nested") == 0);
        MSChatValueFree(root);
    }

    {
        MSChatValue *content = dict();
        MSChatValue *parts = array();
        MSChatValue *part = dict();
        set(part, "parts", string("part text"));
        push(parts, part);
        set(content, "parts", parts);
        root = choicesWithMessage(content);
        CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
        CHECK(strcmp(out, "part text") == 0);
        MSChatValueFree(root);
    }

    // Empty message content falls through to the provider output field.
    root = choicesWithMessage(string(""));
    set(root, "output_text", string("fallback"));
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
    CHECK(strcmp(out, "fallback") == 0);
    MSChatValueFree(root);

    // 0.3.5 shape: choices[0].text and candidates[0].
    root = dict();
    {
        MSChatValue *choices = array();
        MSChatValue *first = dict();
        set(first, "text", string("legacy"));
        push(choices, first);
        set(root, "choices", choices);
    }
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
    CHECK(strcmp(out, "legacy") == 0);
    MSChatValueFree(root);

    root = dict();
    {
        MSChatValue *candidates = array();
        MSChatValue *first = dict();
        MSChatValue *content = dict();
        set(content, "parts", string("gemini"));
        set(first, "content", content);
        push(candidates, first);
        set(root, "candidates", candidates);
    }
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractOK);
    CHECK(strcmp(out, "gemini") == 0);
    MSChatValueFree(root);

    root = string("plain");
    CHECK(MSChatExtractReplyText(root, out, sizeof out) == MSChatExtractShape);
    MSChatValueFree(root);

    // Tiny destination must truncate on a UTF-8 boundary without crashing.
    root = choicesWithMessage(string("中文回复"));
    {
        char tiny[8];
        CHECK(MSChatExtractReplyText(root, tiny, sizeof tiny) == MSChatExtractOK);
        CHECK(strlen(tiny) < sizeof tiny);
        CHECK(strlen(tiny) % 3 == 0);
    }
    MSChatValueFree(root);
}

static void test_status(void) {
    CHECK(MSChatIssueForStatus(0) == MSChatIssueNetwork);
    CHECK(MSChatIssueForStatus(200) == MSChatIssueNone);
    CHECK(MSChatIssueForStatus(204) == MSChatIssueNone);
    CHECK(MSChatIssueForStatus(401) == MSChatIssueHTTP);
    CHECK(MSChatIssueForStatus(401) == MSChatIssueHTTP);
    CHECK(MSChatClassifyStatus(401) == MSChatStatusAuth);
    CHECK(MSChatClassifyStatus(403) == MSChatStatusAuth);
    CHECK(MSChatClassifyStatus(404) == MSChatStatusNotFound);
    CHECK(MSChatClassifyStatus(429) == MSChatStatusRateLimited);
    CHECK(MSChatIssueForStatus(429) == MSChatIssueHTTP);
    CHECK(MSChatClassifyStatus(500) == MSChatStatusServer);
    CHECK(MSChatIssueForStatus(500) == MSChatIssueHTTP);
    CHECK(MSChatClassifyStatus(418) == MSChatStatusOther);

    CHECK(strstr(MSChatMessageForIssue(MSChatIssueConfig, 0), "配置") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueURL, 0), "地址") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueTimeout, 0), "30") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueNetwork, 0), "网络") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueEmpty, 0), "空") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueHTTP, 401), "401") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueHTTP, 429), "429") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueHTTP, 500), "500") != NULL);
    CHECK(strstr(MSChatMessageForIssue(MSChatIssueCancelled, 0), "取消") != NULL);
    CHECK(strlen(MSChatMessageForIssue(MSChatIssueHTTP, 0)) > 0);
}

static void test_state(void) {
    MSChatRequestState state;
    unsigned long first;
    unsigned long second;

    MSChatStateInit(&state);
    CHECK(!MSChatAcceptsReply(&state, 0));
    CHECK(MSChatBeginRequest(&state));
    first = state.generation;
    CHECK(!MSChatBeginRequest(&state));
    CHECK(MSChatAcceptsReply(&state, first));
    CHECK(MSChatCancelRequest(&state));
    CHECK(!MSChatAcceptsReply(&state, first));
    CHECK(!MSChatCancelRequest(&state));
    CHECK(MSChatBeginRequest(&state));
    second = state.generation;
    CHECK(second != first);
    CHECK(!MSChatAcceptsReply(&state, first));
    CHECK(MSChatAcceptsReply(&state, second));
    MSChatFinishRequest(&state, first);   // stale completion cannot clear newer send
    CHECK(state.sending);
    MSChatFinishRequest(&state, second);
    CHECK(!state.sending);
}

int main(void) {
    test_endpoint();
    test_context();
    test_extract();
    test_status();
    test_state();
    printf("chat core: %u checks passed\n", checks);
    return 0;
}
