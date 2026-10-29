//
//  CompatUmbrella.h
//  CompatFW
//
//  modulemap 层 UIKit 传播头(无声明,仅 import):
//  对齐 Acrobits SoftphoneBridge.h 手写 `#import <UIKit/UIKit.h>` 的
//  umbrella 传播——App 工程的 bridging header 只 import 本 SDK 生成头,
//  App 内无 import 的 Swift 文件(NovoEngine 的 UN* 本地通知等)依赖 SDK
//  module 链把 UIKit(及其可见的 UserNotifications 类型)带入可见域。
//  本头经 modulemap 列入 module(underlying),Acrobits 同构机制;
//  实测:`import UIKit` ⇒ UN* 类型可见(SDK 26.2)。
//

#import <UIKit/UIKit.h>
