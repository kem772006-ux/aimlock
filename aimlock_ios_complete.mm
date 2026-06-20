#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <sys/sysctl.h>

static mach_port_t task = MACH_PORT_NULL;
static uint64_t gameBase = 0;
static pid_t gamePid = 0;
static BOOL running = YES;
static CGFloat sw = 0, sh = 0, cx = 0, cy = 0;

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

uint64_t read64(uint64_t a) {
    uint64_t v=0; mach_vm_size_t s=8;
    mach_vm_read_overwrite(task, a, s, (mach_vm_address_t)&v, &s);
    return v;
}
uint32_t read32(uint64_t a) {
    uint32_t v=0; mach_vm_size_t s=4;
    mach_vm_read_overwrite(task, a, s, (mach_vm_address_t)&v, &s);
    return v;
}
Vec3 readVec3(uint64_t a) {
    Vec3 v={0}; mach_vm_size_t s=12;
    mach_vm_read_overwrite(task, a, s, (mach_vm_address_t)&v, &s);
    return v;
}

pid_t findGame(void) {
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};
    size_t sz; sysctl(mib,4,NULL,&sz,NULL,0);
    struct kinfo_proc *p=(struct kinfo_proc*)malloc(sz);
    sysctl(mib,4,p,&sz,NULL,0);
    pid_t r=-1;
    NSArray *names=@[@"PUBGM",@"ShadowTrackerExtra",@"codm",@"freefire",@"bgmi"];
    for(size_t i=0;i<sz/sizeof(*p);i++){
        NSString *n=[NSString stringWithUTF8String:p[i].kp_proc.p_comm];
        for(NSString *g in names){
            if([n localizedCaseInsensitiveContainsString:g]){r=p[i].kp_proc.p_pid;break;}
        }
        if(r!=-1)break;
    }
    free(p); return r;
}

uint64_t findModule(pid_t pid, NSString *name) {
    task_dyld_info_data_t di; mach_msg_type_number_t c=TASK_DYLD_INFO_COUNT;
    task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &c);
    struct dyld_all_image_infos ai; mach_vm_size_t s=sizeof(ai);
    mach_vm_read_overwrite(task, (uint64_t)di.all_image_info_addr, s, (mach_vm_address_t)&ai, &s);
    s=ai.infoArrayCount*sizeof(struct dyld_image_info);
    struct dyld_image_info *arr=(struct dyld_image_info*)malloc(s);
    mach_vm_read_overwrite(task, (uint64_t)ai.infoArray, s, (mach_vm_address_t)arr, &s);
    uint64_t base=0;
    for(uint32_t i=0;i<ai.infoArrayCount;i++){
        char buf[512]={0}; mach_vm_size_t bs=511;
        mach_vm_read_overwrite(task, (uint64_t)arr[i].imageFilePath, bs, (mach_vm_address_t)buf, &bs);
        if([[NSString stringWithUTF8String:buf] containsString:name]){
            base=(uint64_t)arr[i].imageLoadAddress; break;
        }
    }
    free(arr); return base;
}

float dist2d(CGPoint a, CGPoint b) {
    float dx=a.x-b.x, dy=a.y-b.y;
    return sqrtf(dx*dx+dy*dy);
}

CGPoint worldToScreen(Vec3 w, VMatrix m) {
    CGPoint s={0,0};
    float ww=m.m[3][0]*w.x+m.m[3][1]*w.y+m.m[3][2]*w.z+m.m[3][3];
    if(ww<0.01f)return s;
    float iw=1.0f/ww;
    s.x=cx+(cx*(m.m[0][0]*w.x+m.m[0][1]*w.y+m.m[0][2]*w.z+m.m[0][3])*iw);
    s.y=cy-(cy*(m.m[1][0]*w.x+m.m[1][1]*w.y+m.m[1][2]*w.z+m.m[1][3])*iw);
    return s;
}

VMatrix getViewMatrix(void) {
    VMatrix m={0};
    uint64_t cam=read64(gameBase+OFF_CAMERA);
    if(cam){
        mach_vm_size_t s=64;
        mach_vm_read_overwrite(task, cam+0xDC, s, (mach_vm_address_t)&m, &s);
    }
    return m;
}

Vec3 getBonePos(uint64_t obj, int bone) {
    uint64_t t=read64(obj+OFF_TRANSFORM);
    Vec3 pos={0};
    if(t){
        float p[3], ho[3];
        mach_vm_size_t s=12;
        mach_vm_read_overwrite(task, t+0x10, s, (mach_vm_address_t)p, &s);
        mach_vm_read_overwrite(task, t+0x30, s, (mach_vm_address_t)ho, &s);
        float bf=(float)bone/6.0f;
        pos.x=p[0]+ho[0]*bf;
        pos.y=p[1]+ho[1]*bf;
        pos.z=p[2]+ho[2]*bf;
    } else {
        pos=readVec3(obj+OFF_POSITION);
        pos.y+=1.8f*((float)bone/6.0f);
    }
    return pos;
}

BOOL validPlayer(uint64_t obj) {
    if(!obj)return NO;
    int h=read32(obj+OFF_HEALTH);
    int t=read32(obj+OFF_TEAM);
    if(h<=0||h>10000)return NO;
    if(t>100)return NO;
    return YES;
}

void aimloop(void) {
    while(running){
        @autoreleasepool{
            if(!running)break;
            uint64_t lp=read64(gameBase+OFF_LOCAL_PLAYER);
            if(!lp||!validPlayer(lp)){usleep(8000);continue;}
            uint32_t lt=read32(lp+OFF_TEAM);
            VMatrix vm=getViewMatrix();
            uint64_t ea=read64(gameBase+OFF_ENTITY_LIST+0x8);
            uint64_t ec=read64(gameBase+OFF_ENTITY_LIST);
            if(!ea||ec>500){usleep(8000);continue;}
            CGPoint cen={cx,cy};
            float bestDist=999999;
            for(uint64_t i=0;i<(ec<200?ec:200);i++){
                uint64_t e=read64(ea+i*0x8);
                if(e==lp||!validPlayer(e))continue;
                if(read32(e+OFF_TEAM)==lt)continue;
                Vec3 bp=getBonePos(e, AIM_BONE);
                CGPoint sp=worldToScreen(bp, vm);
                if(sp.x<0||sp.x>sw||sp.y<0||sp.y>sh)continue;
                float d=dist2d(sp,cen);
                if(d<AIM_FOV&&d<bestDist)bestDist=d;
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
    static AimController *i=nil;
    static dispatch_once_t o; dispatch_once(&o,^{i=[[AimController alloc]init];});
    return i;
}
- (instancetype)init {
    self=[super init];
    sw=[UIScreen mainScreen].bounds.size.width*[UIScreen mainScreen].scale;
    sh=[UIScreen mainScreen].bounds.size.height*[UIScreen mainScreen].scale;
    cx=sw/2; cy=sh/2;
    return self;
}
- (BOOL)setup {
    NSLog(@"[*] Dang tim game...");
    gamePid=findGame();
    if(gamePid==-1){NSLog(@"[!] Khong tim thay game!");return NO;}
    NSLog(@"[+] PID: %d",gamePid);
    if(task_for_pid(mach_task_self(),gamePid,&task)!=KERN_SUCCESS){
        NSLog(@"[!] Can TrollStore!");return NO;
    }
    NSLog(@"[+] Task OK");
    gameBase=findModule(gamePid, @"UnityFramework");
    if(!gameBase)gameBase=findModule(gamePid, @"libil2cpp.so");
    if(!gameBase){NSLog(@"[!] Khong tim thay module!");return NO;}
    NSLog(@"[+] Base: 0x%llx",gameBase);
    return YES;
}
- (void)start {
    running=YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH,0),^{aimloop();});
    NSLog(@"[+] SAN SANG!");
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool{
        AimController *c=[AimController shared];
        if([c setup]){[c start]; [[NSRunLoop currentRunLoop] run];}
        else{NSLog(@"[!] Loi!"); sleep(5); return -1;}
    }
    return 0;
}
