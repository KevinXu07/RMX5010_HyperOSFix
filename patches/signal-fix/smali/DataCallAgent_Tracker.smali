.class Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;
.super Ljava/lang/Object;
.source "DataCallAgent.java"


# annotations
.annotation system Ldalvik/annotation/EnclosingClass;
    value = Lcom/qualcomm/qti/cne/datacall/DataCallAgent;
.end annotation

.annotation system Ldalvik/annotation/InnerClass;
    accessFlags = 0x2
    name = "Tracker"
.end annotation


# instance fields
.field private mConnectivityManager:Landroid/net/ConnectivityManager;

.field private final mNetType:I

.field private mNetworkCallback:Landroid/net/ConnectivityManager$NetworkCallback;

.field private mRatInfo:Lcom/qualcomm/qti/cne/relay/RatInfo;

.field private final mSlotId:I

.field private final mSubId:I

.field private ratRequestFlag:Z

.field final synthetic this$0:Lcom/qualcomm/qti/cne/datacall/DataCallAgent;


# direct methods
.method public constructor <init>(Lcom/qualcomm/qti/cne/datacall/DataCallAgent;III)V
    .registers 7
    .param p2, "subId"    # I
    .param p3, "slotId"    # I
    .param p4, "netType"    # I
    .annotation system Ldalvik/annotation/MethodParameters;
        accessFlags = {
            0x1010,
            0x0,
            0x0,
            0x0
        }
        names = {
            null,
            null,
            null,
            null
        }
    .end annotation

    .line 367
    iput-object p1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->this$0:Lcom/qualcomm/qti/cne/datacall/DataCallAgent;

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    .line 330
    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->ratRequestFlag:Z

    .line 332
    new-instance v0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker$1;

    invoke-direct {v0, p0}, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker$1;-><init>(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;)V

    iput-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetworkCallback:Landroid/net/ConnectivityManager$NetworkCallback;

    .line 368
    iput p2, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mSubId:I

    .line 369
    iput p3, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mSlotId:I

    .line 370
    iput p4, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetType:I

    .line 371
    new-instance v0, Lcom/qualcomm/qti/cne/relay/RatInfo;

    invoke-direct {v0}, Lcom/qualcomm/qti/cne/relay/RatInfo;-><init>()V

    iput-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mRatInfo:Lcom/qualcomm/qti/cne/relay/RatInfo;

    .line 372
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mRatInfo:Lcom/qualcomm/qti/cne/relay/RatInfo;

    iget v1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetType:I

    invoke-virtual {v0, v1}, Lcom/qualcomm/qti/cne/relay/RatInfo;->setNetworkType(I)V

    .line 373
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mRatInfo:Lcom/qualcomm/qti/cne/relay/RatInfo;

    iget v1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mSlotId:I

    invoke-virtual {v0, v1}, Lcom/qualcomm/qti/cne/relay/RatInfo;->setSlotIdx(I)V

    .line 374
    # getter for: Lcom/qualcomm/qti/cne/datacall/DataCallAgent;->mContext:Landroid/content/Context;
    invoke-static {p1}, Lcom/qualcomm/qti/cne/datacall/DataCallAgent;->access$1000(Lcom/qualcomm/qti/cne/datacall/DataCallAgent;)Landroid/content/Context;

    move-result-object p1

    .line 375
    const-string v0, "connectivity"

    invoke-virtual {p1, v0}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;

    move-result-object p1

    check-cast p1, Landroid/net/ConnectivityManager;

    iput-object p1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mConnectivityManager:Landroid/net/ConnectivityManager;

    .line 376
    return-void
.end method

.method static synthetic access$500(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;)I
    .registers 2
    .param p0, "x0"    # Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;

    .line 323
    iget v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mSubId:I

    return v0
.end method

.method static synthetic access$600(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;)I
    .registers 2
    .param p0, "x0"    # Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;

    .line 323
    iget v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mSlotId:I

    return v0
.end method

.method static synthetic access$700(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;)Landroid/net/ConnectivityManager;
    .registers 2
    .param p0, "x0"    # Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;

    .line 323
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mConnectivityManager:Landroid/net/ConnectivityManager;

    return-object v0
.end method

.method static synthetic access$800(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;)Lcom/qualcomm/qti/cne/relay/RatInfo;
    .registers 2
    .param p0, "x0"    # Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;

    .line 323
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mRatInfo:Lcom/qualcomm/qti/cne/relay/RatInfo;

    return-object v0
.end method

.method static synthetic access$900(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;)Z
    .registers 2
    .param p0, "x0"    # Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;

    .line 323
    iget-boolean v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->ratRequestFlag:Z

    return v0
.end method

.method static synthetic access$902(Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;Z)Z
    .registers 2
    .param p0, "x0"    # Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;
    .param p1, "x1"    # Z

    .line 323
    iput-boolean p1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->ratRequestFlag:Z

    return p1
.end method

.method private getNetworkCapability(I)I
    .registers 5
    .param p1, "netType"    # I

    .line 422
    const/4 v0, -0x1

    .line 423
    .local v0, "capability":I
    sparse-switch p1, :sswitch_data_2e

    .line 443
    new-instance v1, Ljava/lang/StringBuilder;

    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V

    const-string v2, "Unknown network capability: "

    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v1

    invoke-virtual {v1, p1}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    move-result-object v1

    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v1

    const-string v2, "QCNEJ/DataCallAgent"

    invoke-static {v2, v1}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    goto :goto_2c

    .line 434
    :sswitch_1d
    const/4 v0, 0x4

    .line 435
    goto :goto_2c

    .line 440
    :sswitch_1f
    const/16 v0, 0xa

    .line 441
    goto :goto_2c

    .line 437
    :sswitch_22
    const/16 v0, 0x8

    .line 438
    goto :goto_2c

    .line 431
    :sswitch_25
    const/4 v0, 0x1

    .line 432
    goto :goto_2c

    .line 428
    :sswitch_27
    const/4 v0, 0x0

    .line 429
    goto :goto_2c

    .line 425
    :sswitch_29
    const/16 v0, 0xc

    .line 426
    nop

    .line 446
    :goto_2c
    return v0

    nop

    :sswitch_data_2e
    .sparse-switch
        0x0 -> :sswitch_29
        0x2 -> :sswitch_27
        0x3 -> :sswitch_25
        0x5 -> :sswitch_22
        0x6 -> :sswitch_1f
        0xb -> :sswitch_1d
    .end sparse-switch
.end method


# virtual methods
.method public createNetworkRequest()V
    .registers 6

    .line 379
    iget v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetType:I

    invoke-direct {p0, v0}, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->getNetworkCapability(I)I

    move-result v0

    .line 380
    .local v0, "capability":I
    const/4 v1, -0x1

    if-eq v0, v1, :cond_31

    .line 381
    new-instance v1, Landroid/net/NetworkRequest$Builder;

    invoke-direct {v1}, Landroid/net/NetworkRequest$Builder;-><init>()V

    .line 382
    invoke-virtual {v1, v0}, Landroid/net/NetworkRequest$Builder;->addCapability(I)Landroid/net/NetworkRequest$Builder;

    move-result-object v1

    .line 383
    const/4 v2, 0x0

    invoke-virtual {v1, v2}, Landroid/net/NetworkRequest$Builder;->addTransportType(I)Landroid/net/NetworkRequest$Builder;

    move-result-object v1

    .line 384
    invoke-virtual {v1}, Landroid/net/NetworkRequest$Builder;->build()Landroid/net/NetworkRequest;

    move-result-object v1

    .line 386
    .local v1, "netRequest":Landroid/net/NetworkRequest;
    :try_start_1b
    iget-object v2, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mConnectivityManager:Landroid/net/ConnectivityManager;

    iget-object v3, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetworkCallback:Landroid/net/ConnectivityManager$NetworkCallback;

    iget-object v4, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->this$0:Lcom/qualcomm/qti/cne/datacall/DataCallAgent;

    # getter for: Lcom/qualcomm/qti/cne/datacall/DataCallAgent;->mHandler:Landroid/os/Handler;
    invoke-static {v4}, Lcom/qualcomm/qti/cne/datacall/DataCallAgent;->access$000(Lcom/qualcomm/qti/cne/datacall/DataCallAgent;)Landroid/os/Handler;

    move-result-object v4

    invoke-virtual {v2, v1, v3, v4}, Landroid/net/ConnectivityManager;->requestNetwork(Landroid/net/NetworkRequest;Landroid/net/ConnectivityManager$NetworkCallback;Landroid/os/Handler;)V
    :try_end_28
    .catch Ljava/lang/SecurityException; {:try_start_1b .. :try_end_28} :catch_29

    .line 389
    goto :goto_31

    .line 387
    :catch_29
    move-exception v2

    .line 388
    .local v2, "e":Ljava/lang/SecurityException;
    const-string v3, "QCNEJ/DataCallAgent"

    const-string v4, "Unable to request network"

    invoke-static {v3, v4}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    .line 391
    .end local v1    # "netRequest":Landroid/net/NetworkRequest;
    .end local v2    # "e":Ljava/lang/SecurityException;
    :cond_31
    :goto_31
    return-void
.end method

.method public createNetworkRequest(I)V
    .registers 7
    .param p1, "subId"    # I

    .line 394
    iget v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetType:I

    invoke-direct {p0, v0}, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->getNetworkCapability(I)I

    move-result v0

    .line 395
    .local v0, "capability":I
    const/4 v1, -0x1

    if-eq v0, v1, :cond_39

    .line 396
    new-instance v1, Landroid/net/NetworkRequest$Builder;

    invoke-direct {v1}, Landroid/net/NetworkRequest$Builder;-><init>()V

    .line 397
    invoke-virtual {v1, v0}, Landroid/net/NetworkRequest$Builder;->addCapability(I)Landroid/net/NetworkRequest$Builder;

    move-result-object v1

    .line 398
    const/4 v2, 0x0

    invoke-virtual {v1, v2}, Landroid/net/NetworkRequest$Builder;->addTransportType(I)Landroid/net/NetworkRequest$Builder;

    move-result-object v1

    .line 399
    invoke-static {p1}, Ljava/lang/Integer;->toString(I)Ljava/lang/String;

    move-result-object v2

    invoke-virtual {v1, v2}, Landroid/net/NetworkRequest$Builder;->setNetworkSpecifier(Ljava/lang/String;)Landroid/net/NetworkRequest$Builder;

    move-result-object v1

    .line 400
    invoke-virtual {v1}, Landroid/net/NetworkRequest$Builder;->build()Landroid/net/NetworkRequest;

    move-result-object v1

    .line 402
    .local v1, "netRequest":Landroid/net/NetworkRequest;
    :try_start_23
    iget-object v2, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mConnectivityManager:Landroid/net/ConnectivityManager;

    iget-object v3, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetworkCallback:Landroid/net/ConnectivityManager$NetworkCallback;

    iget-object v4, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->this$0:Lcom/qualcomm/qti/cne/datacall/DataCallAgent;

    # getter for: Lcom/qualcomm/qti/cne/datacall/DataCallAgent;->mHandler:Landroid/os/Handler;
    invoke-static {v4}, Lcom/qualcomm/qti/cne/datacall/DataCallAgent;->access$000(Lcom/qualcomm/qti/cne/datacall/DataCallAgent;)Landroid/os/Handler;

    move-result-object v4

    invoke-virtual {v2, v1, v3, v4}, Landroid/net/ConnectivityManager;->requestNetwork(Landroid/net/NetworkRequest;Landroid/net/ConnectivityManager$NetworkCallback;Landroid/os/Handler;)V
    :try_end_30
    .catch Ljava/lang/SecurityException; {:try_start_23 .. :try_end_30} :catch_31

    .line 405
    goto :goto_39

    .line 403
    :catch_31
    move-exception v2

    .line 404
    .local v2, "e":Ljava/lang/SecurityException;
    const-string v3, "QCNEJ/DataCallAgent"

    const-string v4, "Unable to request network"

    invoke-static {v3, v4}, Landroid/util/Log;->e(Ljava/lang/String;Ljava/lang/String;)I

    .line 407
    .end local v1    # "netRequest":Landroid/net/NetworkRequest;
    .end local v2    # "e":Ljava/lang/SecurityException;
    :cond_39
    :goto_39
    return-void
.end method

.method public destroyNetworkRequest()V
    .registers 3

    .line 410
    :try_start_0
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mConnectivityManager:Landroid/net/ConnectivityManager;

    iget-object v1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetworkCallback:Landroid/net/ConnectivityManager$NetworkCallback;

    invoke-virtual {v0, v1}, Landroid/net/ConnectivityManager;->unregisterNetworkCallback(Landroid/net/ConnectivityManager$NetworkCallback;)V
    :try_end_0
    .catch Ljava/lang/IllegalArgumentException; {:try_start_0 .. :try_end_0} :catch_0

    .line 411
    return-void

    :catch_0
    move-exception v0

    const-string v0, "CneDataCallGuard"

    const-string v1, "unregisterNetworkCallback: callback not registered (RMX5010 guard)"

    invoke-static {v0, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method

.method public getRatInfo()Lcom/qualcomm/qti/cne/relay/RatInfo;
    .registers 2

    .line 414
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mRatInfo:Lcom/qualcomm/qti/cne/relay/RatInfo;

    return-object v0
.end method

.method public getRatRequestFlag()Z
    .registers 2

    .line 418
    iget-boolean v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->ratRequestFlag:Z

    return v0
.end method
