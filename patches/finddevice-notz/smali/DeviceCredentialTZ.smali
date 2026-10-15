.class public Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;
.super Lcom/xiaomi/finddevice/v2/AbsDeviceCrendential;
.source "SourceFile"


# static fields
.field private static sInstance:Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;


# direct methods
.method static constructor <clinit>()V
    .registers 1

    new-instance v0, Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;

    invoke-direct {v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;-><init>()V

    sput-object v0, Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;->sInstance:Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;

    return-void
.end method

.method public constructor <init>()V
    .registers 1

    invoke-direct {p0}, Lcom/xiaomi/finddevice/v2/AbsDeviceCrendential;-><init>()V

    return-void
.end method

.method public static get()Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;
    .registers 1

    sget-object v0, Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;->sInstance:Lcom/xiaomi/finddevice/v2/DeviceCredentialTZ;

    return-object v0
.end method


# virtual methods
# --- RMX5010 patch (strategy A, mirrors the verified FdNoTzHook module):
#     delegate the TZ credential face to the NoTZ credential implementation when a
#     Context is available; otherwise fall back to the original TZ implementation.
.method public getFId()Ljava/lang/String;
    .registers 4
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Lbf/i$c;
        }
    .end annotation

    invoke-static {}, Lcom/xiaomi/finddevice/Application;->r()Lcom/xiaomi/finddevice/Application;

    move-result-object v0

    if-eqz v0, :orig

    new-instance v1, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;

    invoke-direct {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;-><init>(Landroid/content/Context;)V

    invoke-virtual {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;->get(Landroid/content/Context;)Lcom/xiaomi/finddevice/v2/IDeviceCredential;

    move-result-object v1

    if-eqz v1, :orig

    invoke-interface {v1}, Lcom/xiaomi/finddevice/v2/IDeviceCredential;->getFId()Ljava/lang/String;

    move-result-object v1

    return-object v1

    :orig
    invoke-static {}, Lbf/i;->g()Lbf/i;

    move-result-object v0

    invoke-virtual {v0}, Lbf/i;->h()Ljava/lang/String;

    move-result-object v0

    return-object v0
.end method

.method public getHost()Ljava/lang/String;
    .registers 4
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Lbf/i$c;
        }
    .end annotation

    invoke-static {}, Lcom/xiaomi/finddevice/Application;->r()Lcom/xiaomi/finddevice/Application;

    move-result-object v0

    if-eqz v0, :orig

    new-instance v1, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;

    invoke-direct {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;-><init>(Landroid/content/Context;)V

    invoke-virtual {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;->get(Landroid/content/Context;)Lcom/xiaomi/finddevice/v2/IDeviceCredential;

    move-result-object v1

    if-eqz v1, :orig

    invoke-interface {v1}, Lcom/xiaomi/finddevice/v2/IDeviceCredential;->getHost()Ljava/lang/String;

    move-result-object v1

    return-object v1

    :orig
    const/4 v0, 0x0

    return-object v0
.end method

.method public getOwnUserId()Ljava/lang/String;
    .registers 4
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Lbf/i$c;
        }
    .end annotation

    invoke-static {}, Lcom/xiaomi/finddevice/Application;->r()Lcom/xiaomi/finddevice/Application;

    move-result-object v0

    if-eqz v0, :orig

    new-instance v1, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;

    invoke-direct {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;-><init>(Landroid/content/Context;)V

    invoke-virtual {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;->get(Landroid/content/Context;)Lcom/xiaomi/finddevice/v2/IDeviceCredential;

    move-result-object v1

    if-eqz v1, :orig

    invoke-interface {v1}, Lcom/xiaomi/finddevice/v2/IDeviceCredential;->getOwnUserId()Ljava/lang/String;

    move-result-object v1

    return-object v1

    :orig
    const/4 v0, 0x0

    return-object v0
.end method

.method public isProvisioned()Z
    .registers 4
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Lbf/i$c;
        }
    .end annotation

    invoke-static {}, Lcom/xiaomi/finddevice/Application;->r()Lcom/xiaomi/finddevice/Application;

    move-result-object v0

    if-eqz v0, :orig

    new-instance v1, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;

    invoke-direct {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;-><init>(Landroid/content/Context;)V

    invoke-virtual {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;->get(Landroid/content/Context;)Lcom/xiaomi/finddevice/v2/IDeviceCredential;

    move-result-object v1

    if-eqz v1, :orig

    const/4 v0, 0x1

    return v0

    :orig
    invoke-static {}, Lbf/i;->g()Lbf/i;

    move-result-object v0

    invoke-virtual {v0}, Lbf/i;->i()Z

    move-result v0

    return v0
.end method

# provision(): report "not provisioned" so callers never drive the unavailable TZ
# provisioning path (module-verified behaviour: unconditional false)
.method public provision(Landroid/content/Context;ZLbf/g;)Z
    .registers 7
    .annotation system Ldalvik/annotation/MethodParameters;
        accessFlags = {
            0x0,
            0x0,
            0x0
        }
        names = {
            "ctx",
            "forceReprovision",
            "keyProvider"
        }
    .end annotation

    .annotation system Ldalvik/annotation/Throws;
        value = {
            Lbf/i$c;,
            Ljava/lang/InterruptedException;,
            Ljh/b$d;,
            Ljh/b$p;,
            Ljh/b$s;,
            Ljh/b$n;,
            Ljava/io/IOException;
        }
    .end annotation

    const/4 v0, 0x0

    return v0
.end method

.method public sign([B)[B
    .registers 5
    .annotation system Ldalvik/annotation/MethodParameters;
        accessFlags = {
            0x0
        }
        names = {
            "src"
        }
    .end annotation

    .annotation system Ldalvik/annotation/Throws;
        value = {
            Lbf/i$c;
        }
    .end annotation

    invoke-static {}, Lcom/xiaomi/finddevice/Application;->r()Lcom/xiaomi/finddevice/Application;

    move-result-object v0

    if-eqz v0, :orig

    new-instance v1, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;

    invoke-direct {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;-><init>(Landroid/content/Context;)V

    invoke-virtual {v1, v0}, Lcom/xiaomi/finddevice/v2/DeviceCredentialManagerNoTZ;->get(Landroid/content/Context;)Lcom/xiaomi/finddevice/v2/IDeviceCredential;

    move-result-object v1

    if-eqz v1, :orig

    invoke-interface {v1, p1}, Lcom/xiaomi/finddevice/v2/IDeviceCredential;->sign([B)[B

    move-result-object v1

    return-object v1

    :orig
    const-string v0, "SHA-256"

    invoke-static {v0}, Ljava/security/MessageDigest;->getInstance(Ljava/lang/String;)Ljava/security/MessageDigest;

    move-result-object v0

    invoke-virtual {v0, p1}, Ljava/security/MessageDigest;->digest([B)[B

    move-result-object v0

    invoke-static {v0}, Lgf/x;->a([B)Ljava/lang/String;

    move-result-object v0

    invoke-static {}, Lbf/i;->g()Lbf/i;

    move-result-object v1

    const/4 v2, 0x1

    invoke-virtual {v1, v2, v0}, Lbf/i;->f(ILjava/lang/String;)Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lgf/x;->b(Ljava/lang/String;)[B

    move-result-object v1

    if-eqz v1, :bad

    invoke-static {v1}, Lgf/x;->f([B)[B

    move-result-object v0

    return-object v0

    :bad
    new-instance v1, Ljava/lang/RuntimeException;

    const-string v2, "MTService returned a bad hexSignString: %s"

    filled-new-array {v0}, [Ljava/lang/Object;

    move-result-object v0

    invoke-static {v2, v0}, Ljava/lang/String;->format(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;

    move-result-object v0

    invoke-direct {v1, v0}, Ljava/lang/RuntimeException;-><init>(Ljava/lang/String;)V

    throw v1
.end method
