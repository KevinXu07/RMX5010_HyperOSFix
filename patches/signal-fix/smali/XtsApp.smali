.class public Lcom/android/phone/XtsApp;
.super Ljava/lang/Object;
.source "XtsApp.java"


# static fields
.field public static mAndroidVersion:I = 0x0

.field public static mBpChipId:I = 0x0

.field public static mBuildProfile:Ljava/lang/String; = "NULL"

.field public static mBuildRegion:Ljava/lang/String; = "none"

.field public static mBuildTags:Ljava/lang/String; = "NULL"

.field public static mBuildVersion:Ljava/lang/String; = ""

.field public static mCertType:Ljava/lang/String; = "none"

.field public static mContext:Landroid/content/Context; = null

.field public static mDeviceHwInfo:Ljava/lang/String; = "NULL"

.field public static mDeviceHwLevel:Ljava/lang/String; = "NULL"

.field public static mDeviceModName:Ljava/lang/String; = "NULL"

.field public static mDeviceName:Ljava/lang/String; = "NULL"

.field public static mFactoryBuild:Ljava/lang/String; = "NULL"

.field public static mHalChipId:I = 0x0

.field private static mHookAgent:Lcom/xiaomi/modem/OemHookAgent; = null

.field private static mHookReadyRegistrants:Lcom/android/internal/telephony/RegistrantList; = null

.field public static mIsHalDecoupled:Z = false

.field public static mManufacturerId:I = 0x0

.field public static mOemProjectFlag:I = 0x0

.field public static mRootType:Ljava/lang/String; = "NULL"

.field public static mSdkVersion:I = 0x0

.field public static mXringHalFlag:Z = false

.field private static mXtsApp:Lcom/android/phone/XtsApp;


# instance fields
.field private mBroadcastReceiver:Landroid/content/BroadcastReceiver;

.field protected mHandler:Landroid/os/Handler;


# direct methods
.method static bridge synthetic -$$Nest$monHookDone(Lcom/android/phone/XtsApp;)V
    .registers 1

    .line 0
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->onHookDone()V

    return-void
.end method

.method static bridge synthetic -$$Nest$smlog(Ljava/lang/String;)V
    .registers 1

    .line 0
    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void
.end method

.method static constructor <clinit>()V
    .registers 1

    .line 82
    new-instance v0, Lcom/android/internal/telephony/RegistrantList;

    invoke-direct {v0}, Lcom/android/internal/telephony/RegistrantList;-><init>()V

    sput-object v0, Lcom/android/phone/XtsApp;->mHookReadyRegistrants:Lcom/android/internal/telephony/RegistrantList;

    return-void
.end method

.method private constructor <init>()V
    .registers 4

    .line 166
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    .line 326
    new-instance v0, Lcom/android/phone/XtsApp$1;

    invoke-direct {v0, p0}, Lcom/android/phone/XtsApp$1;-><init>(Lcom/android/phone/XtsApp;)V

    iput-object v0, p0, Lcom/android/phone/XtsApp;->mHandler:Landroid/os/Handler;

    .line 391
    new-instance v0, Lcom/android/phone/XtsApp$2;

    invoke-direct {v0, p0}, Lcom/android/phone/XtsApp$2;-><init>(Lcom/android/phone/XtsApp;)V

    iput-object v0, p0, Lcom/android/phone/XtsApp;->mBroadcastReceiver:Landroid/content/BroadcastReceiver;

    .line 168
    const-string v0, "Constructor"

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 170
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->onInit()V

    .line 172
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->XiaomiTelephonyComponentFactoryMake()V

    .line 174
    sget-object v0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    iget-object p0, p0, Lcom/android/phone/XtsApp;->mHandler:Landroid/os/Handler;

    const/4 v1, 0x0

    const/4 v2, 0x0

    invoke-static {v0, p0, v1, v2}, Lcom/xiaomi/modem/OemHookAgent;->registerHookReadyEvent(Landroid/content/Context;Landroid/os/Handler;ILjava/lang/Object;)V

    return-void
.end method

.method private XiaomiTelephonyComponentFactoryMake()V
    .registers 3

    .line 180
    invoke-static {}, Lcom/xiaomi/modem/OemHookAgent;->getHookType()I

    move-result p0

    .line 181
    new-instance v0, Ljava/lang/StringBuilder;

    const-string v1, "XiaomiTelephonyComponentFactoryMake, Hook Type = "

    invoke-direct {v0, v1}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-virtual {v0, p0}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    const/4 v0, 0x2

    if-eq p0, v0, :cond_2a

    const/4 v0, 0x1

    if-eq p0, v0, :cond_2a

    const/4 v0, 0x3

    if-eq p0, v0, :cond_2a

    const/4 v0, 0x4

    if-eq p0, v0, :cond_2a

    if-nez p0, :cond_24

    goto :goto_2a

    .line 191
    :cond_24
    const-string p0, "XTS will do nothing for XiaomiTelephonyComponentFactory"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    .line 188
    :cond_2a
    :goto_2a
    const-string p0, "XTS will do XiaomiTelephonyComponentFactory.make"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 189
    sget-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-static {p0}, Lcom/xiaomi/internal/telephony/XiaomiTelephonyComponentFactory;->make(Landroid/content/Context;)V

    return-void
.end method

.method public static isXtsSupported()Z
    .registers 3

    .line 279
    const-string v0, "isXtsSupported"

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 281
    sget-boolean v0, Lcom/android/phone/XtsApp;->mIsHalDecoupled:Z

    const/4 v1, 0x1

    if-ne v1, v0, :cond_1e

    .line 282
    new-instance v0, Ljava/lang/StringBuilder;

    const-string v2, "isXtsSupported, XTS is supported by this HalDecoupled project, mManufacturerId = "

    invoke-direct {v0, v2}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    sget v2, Lcom/android/phone/XtsApp;->mManufacturerId:I

    invoke-virtual {v0, v2}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return v1

    .line 286
    :cond_1e
    sget v0, Lcom/android/phone/XtsApp;->mManufacturerId:I

    if-ne v1, v0, :cond_36

    .line 287
    new-instance v0, Ljava/lang/StringBuilder;

    const-string v2, "isXtsSupported, XTS is supported by this xiaomi project, mManufacturerId = "

    invoke-direct {v0, v2}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    sget v2, Lcom/android/phone/XtsApp;->mManufacturerId:I

    invoke-virtual {v0, v2}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return v1

    .line 291
    :cond_36
    sget v0, Lcom/android/phone/XtsApp;->mHalChipId:I

    const/16 v2, 0x65

    if-eq v2, v0, :cond_72

    const/16 v2, 0x66

    if-eq v2, v0, :cond_72

    const/16 v2, 0x67

    if-ne v2, v0, :cond_45

    goto :goto_72

    .line 300
    :cond_45
    sget v0, Lcom/android/phone/XtsApp;->mOemProjectFlag:I

    if-ne v1, v0, :cond_5e

    .line 301
    new-instance v0, Ljava/lang/StringBuilder;

    const-string v1, "isXtsSupported, XTS is not supported by this odm project, mBpChipId = "

    invoke-direct {v0, v1}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    sget v1, Lcom/android/phone/XtsApp;->mBpChipId:I

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    const/4 v0, 0x0

    return v0

    .line 304
    :cond_5e
    new-instance v0, Ljava/lang/StringBuilder;

    const-string v2, "isXtsSupported, XTS is supported by this xiaomi old project, mBpChipId = "

    invoke-direct {v0, v2}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    sget v2, Lcom/android/phone/XtsApp;->mBpChipId:I

    invoke-virtual {v0, v2}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return v1

    .line 295
    :cond_72
    :goto_72
    new-instance v0, Ljava/lang/StringBuilder;

    const-string v2, "isXtsSupported, XTS is supported by this odm project, mHalChipId = "

    invoke-direct {v0, v2}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    sget v2, Lcom/android/phone/XtsApp;->mHalChipId:I

    invoke-virtual {v0, v2}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return v1
.end method

.method private static log(Ljava/lang/String;)V
    .registers 2

    .line 414
    const-string v0, "XtsApp"

    invoke-static {v0, p0}, Lcom/xiaomi/modem/ModemUtils;->logd(Ljava/lang/String;Ljava/lang/String;)V

    return-void
.end method

.method public static make(Landroid/content/Context;)V
    .registers 3

    .line 93
    new-instance v0, Ljava/lang/StringBuilder;

    const-string/jumbo v1, "make, cnt = "

    invoke-direct {v0, v1}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-virtual {v0, p0}, Ljava/lang/StringBuilder;->append(Ljava/lang/Object;)Ljava/lang/StringBuilder;

    const-string v1, ", mXtsApp = "

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    sget-object v1, Lcom/android/phone/XtsApp;->mXtsApp:Lcom/android/phone/XtsApp;

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/Object;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 95
    sget-object v0, Lcom/android/phone/XtsApp;->mXtsApp:Lcom/android/phone/XtsApp;

    if-eqz v0, :cond_27

    .line 96
    const-string/jumbo p0, "make done, do nothing"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    :cond_27
    if-nez p0, :cond_2f

    .line 101
    const-string p0, "cnt is null, do nothing"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    .line 105
    :cond_2f
    sput-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    .line 107
    new-instance v0, Lcom/android/phone/XtsApp;

    invoke-direct {v0}, Lcom/android/phone/XtsApp;-><init>()V

    sput-object v0, Lcom/android/phone/XtsApp;->mXtsApp:Lcom/android/phone/XtsApp;

    .line 110
    invoke-static {p0}, Lcom/xiaomi/internal/telephony/XmPhoneServiceFactory;->init(Landroid/content/Context;)V

    return-void
.end method

.method private onHookDone()V
    .registers 3

    .line 253
    const-string/jumbo v0, "onHookDone"

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 255
    iget-object v0, p0, Lcom/android/phone/XtsApp;->mHandler:Landroid/os/Handler;

    invoke-static {v0}, Lcom/xiaomi/modem/OemHookAgent;->unregisterHookReadyEvent(Landroid/os/Handler;)V

    .line 256
    invoke-static {}, Lcom/xiaomi/modem/OemHookAgent;->getHook()Lcom/xiaomi/modem/OemHookAgent;

    move-result-object v0

    sput-object v0, Lcom/android/phone/XtsApp;->mHookAgent:Lcom/xiaomi/modem/OemHookAgent;

    .line 257
    invoke-static {v0}, Lcom/xiaomi/modem/ModemUtils;->onInitHook(Lcom/xiaomi/modem/OemHookAgent;)V

    .line 259
    sget-object v0, Lcom/android/phone/XtsApp;->mHookReadyRegistrants:Lcom/android/internal/telephony/RegistrantList;

    monitor-enter v0

    .line 260
    :try_start_17
    sget-object v1, Lcom/android/phone/XtsApp;->mHookReadyRegistrants:Lcom/android/internal/telephony/RegistrantList;

    invoke-virtual {v1}, Lcom/android/internal/telephony/RegistrantList;->notifyRegistrants()V

    .line 261
    monitor-exit v0
    :try_end_1d
    .catchall {:try_start_17 .. :try_end_1d} :catchall_48

    # RMX5010: stop before XTS ver-info / service start; ModemUtils OEM RIL queries block
    # the phone main thread on this Oplus modem (device-verified fix, see repo docs)
    return-void

    .line 263
    sget-object v0, Lcom/android/phone/XtsApp;->mHookAgent:Lcom/xiaomi/modem/OemHookAgent;

    invoke-direct {p0, v0}, Lcom/android/phone/XtsApp;->onInitVerInfo(Lcom/xiaomi/modem/OemHookAgent;)V

    .line 265
    new-instance v0, Ljava/lang/StringBuilder;

    const-string/jumbo v1, "onHookDone, VerInfo = "

    invoke-direct {v0, v1}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-static {}, Lcom/xiaomi/modem/ModemUtils;->getVerInfoWithoutName()Ljava/lang/String;

    move-result-object v1

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 268
    invoke-static {}, Lcom/android/phone/XtsApp;->isXtsSupported()Z

    move-result v0

    if-nez v0, :cond_44

    .line 269
    const-string p0, "Xts is not supported, will do nothing"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    .line 273
    :cond_44
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->onInitByHook()V

    return-void

    :catchall_48
    move-exception p0

    .line 261
    :try_start_49
    monitor-exit v0
    :try_end_4a
    .catchall {:try_start_49 .. :try_end_4a} :catchall_48

    throw p0
.end method

.method private onInit()V
    .registers 2

    .line 198
    const-string/jumbo v0, "onInit"

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 200
    sget-object v0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-static {v0}, Lcom/xiaomi/modem/ModemUtils;->onInitContext(Landroid/content/Context;)V

    .line 202
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->onInitVerInfo()V

    .line 204
    new-instance p0, Ljava/lang/StringBuilder;

    const-string/jumbo v0, "onInit, "

    invoke-direct {p0, v0}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-static {}, Lcom/xiaomi/modem/ModemUtils;->getVerInfoWithName()Ljava/lang/String;

    move-result-object v0

    invoke-virtual {p0, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {p0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object p0

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void
.end method

.method private onInitByHook()V
    .registers 4

    .line 312
    const-string/jumbo v0, "onInitByHook done"

    const-string v1, "Exception e: "

    const-string/jumbo v2, "onInitByHook"

    invoke-static {v2}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 315
    :try_start_b
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->startXtsService()V

    .line 316
    invoke-direct {p0}, Lcom/android/phone/XtsApp;->onRegisterReceiver()V
    :try_end_11
    .catch Ljava/lang/Exception; {:try_start_b .. :try_end_11} :catch_17
    .catchall {:try_start_b .. :try_end_11} :catchall_15

    .line 321
    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    :catchall_15
    move-exception p0

    goto :goto_2e

    :catch_17
    move-exception p0

    .line 318
    :try_start_18
    new-instance v2, Ljava/lang/StringBuilder;

    invoke-direct {v2, v1}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-virtual {v2, p0}, Ljava/lang/StringBuilder;->append(Ljava/lang/Object;)Ljava/lang/StringBuilder;

    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v1

    invoke-static {v1}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 319
    invoke-virtual {p0}, Ljava/lang/Exception;->printStackTrace()V
    :try_end_2a
    .catchall {:try_start_18 .. :try_end_2a} :catchall_15

    .line 321
    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    :goto_2e
    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 322
    throw p0
.end method

.method private onInitVerInfo()V
    .registers 1

    # RMX5010: skip Xiaomi OEM modem version queries (Oplus modem does not answer
    # them; the query blocks the phone main thread and produced SIM/STK ANRs)
    return-void

.end method

.method private onInitVerInfo(Lcom/xiaomi/modem/OemHookAgent;)V
    .registers 3

    # RMX5010: skip Xiaomi OEM modem version queries (Oplus modem does not answer
    # them; the query blocks the phone main thread and produced SIM/STK ANRs)
    return-void

.end method

.method private onRegisterReceiver()V
    .registers 4

    .line 376
    const-string/jumbo v0, "onRegisterReceiver"

    invoke-static {v0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 378
    sget-object v0, Lcom/android/phone/XtsApp;->mHookAgent:Lcom/xiaomi/modem/OemHookAgent;

    if-nez v0, :cond_11

    .line 379
    const-string/jumbo p0, "mHookAgent is null"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    return-void

    .line 383
    :cond_11
    new-instance v0, Landroid/content/IntentFilter;

    invoke-direct {v0}, Landroid/content/IntentFilter;-><init>()V

    .line 387
    sget-object v1, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    iget-object p0, p0, Lcom/android/phone/XtsApp;->mBroadcastReceiver:Landroid/content/BroadcastReceiver;

    const/4 v2, 0x2

    invoke-virtual {v1, p0, v0, v2}, Landroid/content/Context;->registerReceiver(Landroid/content/BroadcastReceiver;Landroid/content/IntentFilter;I)Landroid/content/Intent;

    return-void
.end method

.method private startXtsService()V
    .registers 4

    .line 356
    new-instance p0, Ljava/lang/StringBuilder;

    const-string/jumbo v0, "startXtsService, Hook Type = "

    invoke-direct {p0, v0}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-static {}, Lcom/xiaomi/modem/OemHookAgent;->getHookType()I

    move-result v0

    invoke-virtual {p0, v0}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    const-string v0, ", mContext = "

    invoke-virtual {p0, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    sget-object v0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-virtual {p0, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/Object;)Ljava/lang/StringBuilder;

    invoke-virtual {p0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object p0

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 358
    sget-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    new-instance v0, Landroid/content/Intent;

    sget-object v1, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    const-class v2, Lcom/android/phone/XtsService;

    invoke-direct {v0, v1, v2}, Landroid/content/Intent;-><init>(Landroid/content/Context;Ljava/lang/Class;)V

    invoke-virtual {p0, v0}, Landroid/content/Context;->startService(Landroid/content/Intent;)Landroid/content/ComponentName;

    .line 360
    invoke-static {}, Lcom/xiaomi/modem/OemHookAgent;->getHookType()I

    move-result p0

    const/4 v0, 0x2

    if-ne p0, v0, :cond_40

    .line 361
    const-string p0, "Qcom XTS will start Service"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 362
    sget-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-static {p0}, Lcom/xiaomi/internal/telephony/ModemDumpServiceConfig;->startService(Landroid/content/Context;)V

    return-void

    .line 363
    :cond_40
    invoke-static {}, Lcom/xiaomi/modem/OemHookAgent;->getHookType()I

    move-result p0

    const/4 v0, 0x1

    if-ne p0, v0, :cond_57

    .line 364
    const-string p0, "MTK XTS will start Service"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 365
    sget-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-static {p0}, Lcom/xiaomi/internal/telephony/ModemDumpServiceConfig;->startService(Landroid/content/Context;)V

    .line 366
    sget-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-static {p0}, Lcom/xiaomi/internal/telephony/ModemServiceMoniter;->onMtbServiceWakeUp(Landroid/content/Context;)V

    return-void

    .line 367
    :cond_57
    invoke-static {}, Lcom/xiaomi/modem/OemHookAgent;->getHookType()I

    move-result p0

    const/4 v0, 0x3

    if-ne p0, v0, :cond_68

    .line 368
    const-string p0, "XRING XTS will start Service"

    invoke-static {p0}, Lcom/android/phone/XtsApp;->log(Ljava/lang/String;)V

    .line 369
    sget-object p0, Lcom/android/phone/XtsApp;->mContext:Landroid/content/Context;

    invoke-static {p0}, Lcom/xiaomi/internal/telephony/ModemDumpServiceConfig;->startService(Landroid/content/Context;)V

    :cond_68
    return-void
.end method
