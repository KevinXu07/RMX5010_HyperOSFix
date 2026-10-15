.class public Lgf/s0;
.super Ljava/lang/Object;
.source "SourceFile"


# annotations
.annotation system Ldalvik/annotation/MemberClasses;
    value = {
        Lgf/s0$b;
    }
.end annotation


# direct methods
.method public constructor <init>()V
    .registers 1

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

# --- RMX5010 patch: report the NoTZ credential type id so the credential chain
#     does not call the unavailable TZ cardapp service (upstream throws "empty TZ id")
.method public static a()Ljava/lang/String;
    .registers 6
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Ljava/lang/InterruptedException;,
            Lgf/s0$b;
        }
    .end annotation

    const-string v0, ""

    return-object v0
.end method
