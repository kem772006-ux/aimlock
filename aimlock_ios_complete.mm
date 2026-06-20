#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <sys/sysctl.h>

static mach_port_t gTask = MACH_PORT_NULL;
static uint64_t gGameBase = 0;
static pid_t gGamePid = 0;
static BOOL gRunning = YES;
static CGFloat gSW = 0, gSH = 0, gCX = 0, gCY = 0;

static uint64_t OFF_ENTITY_LIST = 0x1A5E4B0;
static uint64_t OFF_LOCAL_PLAYER = 0x1A2F8C8;
static uint64_t OFF_CAMERA = 0x1A2F9D0;
static uint64_t OFF_TEAM = 0x9C;
static uint64_t OFF_HEALTH = 0xA8;
static uint64_t OFF_POSITION = 0x60;
static uint64_t OFF_TRANSFORM = 0x30;

static float AIM_FOV = 300.0f;
static float AIM_SMOOTH = 6.0f;
static int AIM_BONE = 6;

typedef struct { float x, y, z; } Vec3;
typedef struct { float m[4][4]; } VMatrix;

uint64_t read64(uint64_t addr) {
    uint64_t v = 0;
    vm_size_t s = 8;
    vm_read_overwrite(gTask, (vm_address_t)addr, s, (vm_address_t)&v, &s);
    return v;
}
uint32_t read32(uint64_t addr) {
    uint32_t v = 0;
    vm_size_t s = 4;
    vm_read_overwrite(gTask, (vm_address_t)addr, s, (vm_address_t)&v, &s);
    return v;
}
Vec3 readVec3(uint64_t addr) {
    Vec3 v = {0};
    vm_size_t s = 12;
    vm_read_overwrite(gTask, (vm_address_t)addr, s, (vm_address_t)&v, &s);
    return v;
}

pid_t findGame(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz;
    sysctl(mib, 4, NULL, &sz, NULL, 0);
    struct kinfo_proc *p = (struct kinfo_proc*)malloc(sz);
    sysctl(mib, 4, p, &sz, NULL, 0);
    pid_t r = -1;
    NSArray *names = @[@"PUBGM",@"ShadowTrackerExtra",@"codm",@"freefire",@"bgmi"];
    for(size_t i = 0; i < sz/sizeof(*p); i++) {
        NSString *n = [NSString stringWithUTF8String:p[i].kp_proc.p_comm];
        for(NSString *g in names) {
            if([n localizedCaseInsensitiveContainsString:g]) {
                r = p[i].kp_proc.p_pid;
                break;
            }
        }
        if(r != -1) break;
    }
    free(p);
    return r;
}

uint64_t findModuleBase(NSString *modName) {
    vm_address_t addr = 0;
    vm_size_t size = 0;
    while(1) {
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        struct vm_region_basic_info_64 info;
        mach_port_t obj;
        kern_return_t kr = vm_region_64(gTask, &addr, &size, VM_REGION_BASIC_INFO_64,
                                         (vm_region_info_t)&info, &count, &obj);
        if(kr != KERN_SUCCESS) break;
        if(info.protection & VM_PROT_READ) {
            char buf[512] = {0};
            vm_size_t rs = 511;
            vm_read_overwrite(gTask, addr, rs, (vm_address_t)buf, &rs);
            NSString *s = [NSString stringWithUTF8String:buf];
            if([s containsString:modName]) {
                return addr;
            }
        }
        addr += size;
        if(addr > 0x300000000) break;
    }
    return 0;
}

float dist2d(CGPoint a, CGPoint b) {
    float dx = a.x - b.x, dy = a.y - b.y;
    return sqrtf(dx*dx + dy*dy);
}

CGPoint worldToScreen(Vec3 w, VMatrix m) {
    CGPoint s = {0, 0};
    float ww = m.m[3][0]*w.x + m.m[3][1]*w.y + m.m[3][2]*w.z + m.m[3][3];
    if(ww < 0.01f) return s;
    float iw = 1.0f / ww;
    s.x = gCX + (gCX * (m.m[0][0]*w.x + m.m[0][1]*w.y + m.m[0][2]*w.z + m.m[0][3]) * iw);
    s.y = gCY - (gCY * (m.m[1][0]*w.x + m.m[1][1]*w.y + m.m[1][2]*w.z + m.m[1][3]) * iw);
    return s;
}

VMatrix getViewMatrix(void) {
    VMatrix m = {0};
    uint64_t cam = read64(gGameBase + OFF_CAMERA);
    if(cam) {
        vm_size_t s = 64;
        vm_read_overwrite(gTask, (vm_address_t)(cam + 0xDC), s, (vm_address_t)&m, &s);
    }
    return m;
}

Vec3 getBonePos(uint64_t obj, int bone) {
    uint64_t t = read64(obj + OFF_TRANSFORM);
    Vec3 pos = {0};
    if(t) {
        float p[3], ho[3];
        vm_size_t s = 12;
        vm_read_overwrite(gTask, (vm_address_t)(t + 0x10), s, (vm_address_t)p, &s);
        vm_read_overwrite(gTask, (vm_address_t)(t + 0x30), s, (vm_address_t)ho, &s);
        float bf = (float)bone / 6.0f;
        pos.x = p[0] + ho[0] * bf;
        pos.y = p[1] + ho[1] * bf;
        pos.z = p[2] + ho[2] * bf;
    } else {
        pos = readVec3(obj + OFF_POSITION);
        pos.y += 1.8f * ((float)bone / 6.0f);
    }
    return pos;
}

BOOL validPlayer(uint64_t obj) {
    if(!obj) return NO;
    int h = read32(obj + OFF_HEALTH);
    int t = read32(obj + OFF_TEAM);
    if(h <= 0 || h > 10000) return NO;
    if(t > 100) return NO;
    return YES;
}

void aimloop(void) {
    while(gRunning) {
        @autoreleasepool {
            if(!gRunning) break;
            uint64_t lp = read64(gGameBase + OFF_LOCAL_PLAYER);
            if(!lp || !validPlayer(lp)) { usleep(8000); continue; }
            uint32_t lt = read32(lp + OFF_TEAM);
            VMatrix vm = getViewMatrix();
            uint64_t ea = read64(gGameBase + OFF_ENTITY_LIST + 0x8);
            uint64_t ec = read64(gGameBase + OFF_ENTITY_LIST);
            if(!ea || ec > 500) { usleep(8000); continue; }
            CGPoint cen = {gCX, gCY};
            for(uint64_t i = 0; i < (ec < 200 ? ec : 200); i++) {
                uint64_t e = read64(ea + i * 0x8);
                if(e == lp || !validPlayer(e)) continue;
                if(read32(e + OFF_TEAM) == lt) continue;
                Vec3 bp = getBonePos(e, AIM_BONE);
                CGPoint sp = worldToScreen(bp, vm);
                if(sp.x < 0 || sp.x > gSW || sp.y < 0 || sp.y > gSH) continue;
            }
            usleep(4000);
        }
    }
}

@interface AimController : NSObject
+ (instancetype)shared;
- (BOOL)setup;
- (void)start;
@end

@implementation AimController
+ (instancetype)shared {
    static AimController *i = nil;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [[AimController alloc] init]; });
    return i;
}
- (instancetype)init {
    self = [super init];
    gSW = [UIScreen mainScreen].bounds.size.width * [UIScreen mainScreen].scale;
    gSH = [UIScreen mainScreen].bounds.size.height * [UIScreen mainScreen].scale;
    gCX = gSW / 2;
    gCY = gSH / 2;
    return self;
}
- (BOOL)setup {
    NSLog(@"[*] Tim game...");
    gGamePid = findGame();
    if(gGamePid == -1) {
        NSLog(@"[!] Khong tim thay game!");
        return NO;
    }
    NSLog(@"[+] PID: %d", gGamePid);
    if(task_for_pid(mach_task_self(), gGamePid, &gTask) != KERN_SUCCESS) {
        NSLog(@"[!] Can TrollStore!");
        return NO;
    }
    NSLog(@"[+] Task OK");
    gGameBase = findModuleBase(@"UnityFramework");
    if(!gGameBase) gGameBase = findModuleBase(@"libil2cpp");
    if(!gGameBase) {
        NSLog(@"[!] Khong tim thay module!");
        return NO;
    }
    NSLog(@"[+] Base: 0x%llx", gGameBase);
    return YES;
}
- (void)start {
    gRunning = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        aimloop();
    });
    NSLog(@"[+] OK");
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        AimController *c = [AimController shared];
        if([c setup]) {
            [c start];
            [[NSRunLoop currentRunLoop] run];
        } else {
            sleep(5);
            return -1;
        }
    }
    return 0;
}
