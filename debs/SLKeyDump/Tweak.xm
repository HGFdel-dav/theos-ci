// 验证：能否在插件进程里 dlopen 闪连的主程序，并找到加密函数
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#define L @"/var/mobile/Library/Preferences/sl-dlopen.log"

static void WL(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@\n", s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:L];
    if (!fh) [line writeToFile:L atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

__attribute__((constructor)) static void Init(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WL(@"=== dlopen test ===");
        const char *path = "/var/containers/Bundle/Application/B50A8D68-54AA-47F7-9273-F3EB11B692B1/Runner.app/Runner";
        void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        WL(@"dlopen(%s) = %p, err=%s", path, h, dlerror() ?: "-");
        if (!h) return;
        // 尝试找 CryptoKit 的 seal 符号
        const char *syms[] = {
            "_$s9CryptoKit3AESO3GCMO4seal_5using5nonceAE9SealedBoxVx_AA12SymmetricKeyVAE5NonceVSgtK10Foundation12DataProtocolRzlFZ",
        };
        for (int i = 0; i < 1; i++) {
            void *p = dlsym(h, syms[i]);
            WL(@"dlsym seal = %p err=%s", p, dlerror() ?: "-");
        }
        // 找任何含 AES/GCM 的符号
        int found = 0;
        for (uint32_t img = 0; img < _dyld_image_count(); img++) {
            const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(img);
            if (!mh || mh->magic != MH_MAGIC_64) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(img);
            uintptr_t cur = (uintptr_t)mh + sizeof(struct mach_header_64);
            for (uint32_t c = 0; c < mh->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)cur;
                if (lc->cmd == LC_SYMTAB) {
                    const struct symtab_command *sc = (const struct symtab_command *)lc;
                    const char *strtab = (const char *)((uintptr_t)mh + sc->stroff);
                    const struct nlist_64 *syms = (const struct nlist_64 *)((uintptr_t)mh + sc->symoff);
                    for (uint32_t s = 0; s < sc->nsyms; s++) {
                        if (!syms[s].n_un.n_strx) continue;
                        const char *nm = strtab + syms[s].n_un.n_strx;
                        if (strstr(nm, "GCM") && strstr(nm, "seal")) {
                            WL(@"seal sym in img%d %s -> %p", img, nm, (void *)(syms[s].n_value + slide));
                            found++;
                        }
                    }
                }
                cur += lc->cmdsize;
            }
        }
        WL(@"seal symbols found: %d", found);
    });
}
