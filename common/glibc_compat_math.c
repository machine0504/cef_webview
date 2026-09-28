/*
 * glibc 2.29 数学符号兼容垫片（仅 Linux aarch64 旧 glibc 需要）。
 *
 * 背景：CEF 99 的 linuxarm64 预编译 libcef.so 引用了 exp/log/pow/exp2/log2 的
 * @GLIBC_2.29 版本符号（glibc 2.29 起这些函数获得新版本节点）。在 glibc 2.27/2.28
 * 的系统（构建用 Ubuntu 18.04、目标统信 UOS V20）上该版本节点不存在，链接/运行期
 * 报 "undefined reference to exp@GLIBC_2.29"。
 *
 * 这些函数的实现一直都在（@GLIBC_2.17），只是版本节点不同。本文件用 .symver 提供
 * exp@GLIBC_2.29 等版本符号，转调系统 libm 的旧版实现，满足 CEF 的引用。
 *
 * 仅 aarch64 编译出内容；x86_64 / 非 glibc 平台为空（无副作用）。链接进直接依赖
 * libcef.so 的目标（cef_webview_engine、cef_webview_subprocess）即可。
 */
#if defined(__aarch64__)

/* 转调 libm 旧实现（默认版本，在旧 glibc 上即 @GLIBC_2.17）。
 * 用内部隐藏名，避免与下面提供的 @GLIBC_2.29 版本符号冲突。 */
double __compat_exp_229(double x);
double __compat_exp2_229(double x);
double __compat_log_229(double x);
double __compat_log2_229(double x);
double __compat_pow_229(double x, double y);

extern double exp(double);
extern double exp2(double);
extern double log(double);
extern double log2(double);
extern double pow(double, double);

double __compat_exp_229(double x) { return exp(x); }
double __compat_exp2_229(double x) { return exp2(x); }
double __compat_log_229(double x) { return log(x); }
double __compat_log2_229(double x) { return log2(x); }
double __compat_pow_229(double x, double y) { return pow(x, y); }

/* 提供 @GLIBC_2.29 版本节点的定义，满足 CEF 预编译库的版本化引用。
 * 用 @@ 不可（会与系统默认冲突），用单 @ 提供非默认版本定义。 */
__asm__(".symver __compat_exp_229,exp@GLIBC_2.29");
__asm__(".symver __compat_exp2_229,exp2@GLIBC_2.29");
__asm__(".symver __compat_log_229,log@GLIBC_2.29");
__asm__(".symver __compat_log2_229,log2@GLIBC_2.29");
__asm__(".symver __compat_pow_229,pow@GLIBC_2.29");

#endif
