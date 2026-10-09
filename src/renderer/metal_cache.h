/* Renderer-thread-owned caches. Sources are local game-derived data, never part
 * of the app/repository. Bad, incompatible or unwritable caches are optional. */
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
static NSString *dsr_digest(NSString *text)
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding]; unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (unsigned k = 0; k < sizeof hash; k++) sprintf(hex + 2 * k, "%02x", hash[k]);
    return @(hex);
}
@interface DSRMetalCache : NSObject {
@public
    id<MTLDevice> device; id<MTLBinaryArchive> archive;
    NSMutableDictionary<NSString *, id<MTLFunction>> *functions;
    NSMutableDictionary<NSString *, NSDictionary *> *sources;
    NSString *directory; BOOL dirty, archiveReadOnly; double changed, saved;
    NSUInteger functionHits, functionMisses, pipelineHits, pipelineMisses, sourceBytes;
}
- (instancetype)initWithDevice:(id<MTLDevice>)dev;
- (id<MTLFunction>)function:(NSString *)source entry:(NSString *)entry error:(NSError **)error;
- (id<MTLRenderPipelineState>)pipeline:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error;
- (void)warm;
- (void)save:(BOOL)force;
@end
@implementation DSRMetalCache
- (instancetype)initWithDevice:(id<MTLDevice>)dev
{
    if (!(self = [super init])) return nil;
    device = dev; functions = [NSMutableDictionary new]; sources = [NSMutableDictionary new];
    const char *enabled = getenv("DSR_SHADER_CACHE");
    if (enabled && !strcmp(enabled, "0")) return self;
    NSString *base = getenv("DSR_CACHE_DIR") ? @(getenv("DSR_CACHE_DIR")) :
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"io.github.sims-2-macos/Metal"];
    // Version covers compiler options/manifest format; OS/driver and GPU changes get a fresh archive.
    NSString *identity = [NSString stringWithFormat:@"v2-safe-invariant-colour-%llu-%@", dev.registryID, NSProcessInfo.processInfo.operatingSystemVersionString];
    directory = [base stringByAppendingPathComponent:dsr_digest(identity)];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) { directory = nil; return self; }
    archiveReadOnly = [NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"archive-read-only"]];
    MTLBinaryArchiveDescriptor *desc = [MTLBinaryArchiveDescriptor new];
    NSString *path = [directory stringByAppendingPathComponent:@"pipelines.metalarc"];
    NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (attr && [attr fileSize] < 64u * 1024 * 1024) desc.url = [NSURL fileURLWithPath:path];
    NSError *archiveError = nil; archive = [dev newBinaryArchiveWithDescriptor:desc error:&archiveError];
    if (!archive) { desc.url = nil; archive = [dev newBinaryArchiveWithDescriptor:desc error:&archiveError]; }
    path = [directory stringByAppendingPathComponent:@"sources.plist"];
    attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (attr && [attr fileSize] < 8u * 1024 * 1024) {
        NSDictionary *records = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([records isKindOfClass:NSDictionary.class]) for (id key in records) {
            id rec = records[key]; if (![key isKindOfClass:NSString.class] || ![rec isKindOfClass:NSDictionary.class]) continue;
            NSString *text = rec[@"source"], *entry = rec[@"entry"];
            if (![text isKindOfClass:NSString.class] || ![entry isKindOfClass:NSString.class] || text.length > 262144 || sources.count >= 1024) continue;
            if (![key isEqual:dsr_digest([entry stringByAppendingString:text])]) continue;
            sources[key] = rec; sourceBytes += [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
    }
    return self;
}
- (id<MTLFunction>)function:(NSString *)source entry:(NSString *)entry error:(NSError **)error
{
    NSError *__autoreleasing localError = nil; if (!error) error = &localError;
    NSString *key = dsr_digest([entry stringByAppendingString:source]);
    id<MTLFunction> fn = functions[key]; if (fn) { functionHits++; return fn; }
    functionMisses++;
    MTLCompileOptions *o = [MTLCompileOptions new]; o.preserveInvariance = YES;
    if (@available(macOS 15.0, *)) o.mathMode = MTLMathModeSafe;
    else { _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"") o.fastMathEnabled = NO; _Pragma("clang diagnostic pop") }
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:o error:error];
    fn = lib ? [lib newFunctionWithName:entry] : nil;
    if (fn) {
        functions[key] = fn;
        NSUInteger bytes = [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (directory && !sources[key] && sources.count < 1024 && bytes <= 262144 && sourceBytes + bytes < 6u * 1024 * 1024) {
            sources[key] = @{@"source": source, @"entry": entry}; sourceBytes += bytes; dirty = YES; changed = CACurrentMediaTime();
        }
    }
    return fn;
}
- (void)warm
{
    double start = CACurrentMediaTime(); NSUInteger n = 0;
    for (NSDictionary *record in sources.allValues) if ([self function:record[@"source"] entry:record[@"entry"] error:nil]) n++;
    if (n) fprintf(stderr, "dsr: shader cache warmed %lu stages in %.1f ms\n", (unsigned long)n, (CACurrentMediaTime() - start) * 1000);
}
- (id<MTLRenderPipelineState>)pipeline:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
    NSError *cacheError = nil; NSError *__autoreleasing localError = nil; if (!error) error = &localError;
    d.binaryArchives = archive ? @[archive] : @[];
    // Some Apple drivers cannot serialize vertex-only/depth-only pipelines
    // (gpuarchiver expects a fragment stage). Keep those in the in-memory cache.
    if (!d.fragmentFunction || d.colorAttachments[0].writeMask == MTLColorWriteMaskNone) {
        d.binaryArchives = @[];
        return [device newRenderPipelineStateWithDescriptor:d error:error];
    }
    id<MTLRenderPipelineState> pso = nil;
    if (archive) {
        d.binaryArchives = @[archive];
        pso = [device newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&cacheError];
        if (pso) { pipelineHits++; return pso; }
    }
    pipelineMisses++;
    pso = [device newRenderPipelineStateWithDescriptor:d error:error];
    if (pso && archive && !archiveReadOnly && [archive addRenderPipelineFunctionsWithDescriptor:d error:&cacheError]) { dirty = YES; changed = CACurrentMediaTime(); }
    return pso;
}
- (void)save:(BOOL)force
{
    if (!directory || !dirty) return;
    double now = CACurrentMediaTime();
    if (!force && (now - changed < 0.25 || now - saved < 10)) return;
    saved = now;
    // Atomic replacement leaves a usable previous archive if serialization fails.
    NSString *path = [directory stringByAppendingPathComponent:@"pipelines.metalarc"];
    NSString *tmp = [path stringByAppendingFormat:@".%d.tmp", getpid()];
    NSError *writeError = nil;
    BOOL writingArchive = archive && !archiveReadOnly;
    BOOL ok = !writingArchive || [archive serializeToURL:[NSURL fileURLWithPath:tmp] error:&writeError];
    if (!ok) {
        fprintf(stderr, "dsr: pipeline archive write disabled: %s\n", writeError.localizedDescription.UTF8String ?: "unknown error");
        archive = nil; archiveReadOnly = YES;
        // Keep the last successfully saved archive readable on later launches.
        // Avoid retrying a known driver serialization failure on every launch;
        // a changed OS/GPU/compiler policy selects a fresh cache directory.
        [@"Driver serialization failed; retaining last good archive and source warmup.\n"
            writeToFile:[directory stringByAppendingPathComponent:@"archive-read-only"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    if (writingArchive && archive && ok) ok = rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(tmp.fileSystemRepresentation);
    ok = [sources writeToFile:[directory stringByAppendingPathComponent:@"sources.plist"] atomically:YES] && ok;
    if (ok) dirty = NO;
}
@end
