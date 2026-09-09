# 微信文件与会话关联研究

研究时间：2026-09-09。目标：在文件列表与详情中显示文件属于哪个对话、对话叫什么。

## 当前验证结果

- 本机 `/Applications/WeChat.app` 版本为 4.1.11；微信进程正在运行。
- 已有实验 `Lab/WeChat4x/Reports/db_schema.json` 记录了 25 个数据库，24 个不是标准 SQLite 文件头。此为历史样本，不能当作本次数据库的检查结果。
- 首次访问目录超时；用户确认没有授权弹窗后再次检查已成功。当前 1 个账号下 contact/session/message/hardlink 四类共 16 个数据库均为 `encrypted_or_unknown`，全部存在 WAL。目录访问已恢复，先前超时原因尚不确定。
- 尚未取得可读的本机会话/联系人数据库，也未验证任何真实文件的会话名。应用原有 `conversationName` 字段仍未接入数据源。
- 本机 SIP 已开启，微信签名权限中没有 `get-task-allow`。用临时编译的最小程序调用 `task_for_pid` 检查当前用户读取微信进程的能力，返回 `KERN_FAILURE (5)`；没有读取进程内存、暂停微信或修改签名。这仅证明当前调用失败，不证明所有获取密钥的路径都不可用。

## 待本机验证的关联规则

公开实现给出以下候选链路，不能直接视为 Mac 4.1.11 的已验证协议：

| 数据 | 候选作用 | 本机需要核验 |
| --- | --- | --- |
| `contact/contact.db` | 联系人、备注、昵称 | 实际表列、群聊名称来源、重名与空名称处理 |
| `session/session.db` | 会话 ID 与近期会话信息 | 历史/隐藏会话是否缺失，不可作为唯一全集 |
| `message/message_*.db` | 按会话分表的消息记录 | 分片与会话 ID 的关系 |
| `message/message_resource.db` | 消息 ID 到媒体资源的索引 | 资源 ID、相对路径与会话之间的精确关联 |
| `hardlink/hardlink.db` | 内容与文件目录的辅助索引 | 索引是否完整、延迟、多对多关系 |

Linux 微信 4.x 的开源实现使用 `Msg_<MD5(chatId)>` 消息表以及
`msg/attach/<MD5(chatId)>/<月份>/Img/` 图片目录。若本机验证成立，联系人
ID 正向计算 MD5 后可建立目录索引；不需要反解 MD5。普通文件和视频不能直接
套用图片规则，更不能只凭同名文件或相同内容散列推断唯一会话。

来源：[agent-wechat 实现说明](https://github.com/thisnick/agent-wechat/blob/main/AGENT.md)、
[媒体查询源码](https://github.com/thisnick/agent-wechat/blob/main/packages/agent-server-rust/src/tools/wechat_media.rs)。

Mac 社区解密项目将 4.x 描述为 SQLCipher 数据库；但非 SQLite 文件头只能证明
普通 SQLite 无法直接读，具体密码参数、每库密钥与版本兼容性仍需实际解密校验。
来源：[macOS 3.x / 4.x 解密对照](https://github.com/raclen/wechat-suite/blob/main/wechat-decrypt/docs/macos-3x-vs-4x-decryption-guide.md)。

## 本次新增的诊断入口

```sh
python3 Scripts/inspect-wechat-databases.py --timeout 20
# 也可指定 xwechat_files 或单个账号目录
python3 Scripts/inspect-wechat-databases.py --root /path/to/account
python3 -m unittest discover -s Tests/DatabaseResearchTests -v
```

该入口不是解密器。仅检查 contact/session/message/hardlink 数据库的文件头与
可读 schema，不查询消息/联系人记录，不输出密钥、文件头内容或账号目录名。
账号指纹仅作报告内区分，不应视为不可关联的匿名信息。
可选 `--output` 创建权限为 0600 的新报告，不覆盖已有文件。

标准 SQLite 使用 `mode=ro&immutable=1`，不写入微信目录；只读主文件的已
checkpoint 部分，并显式标记 WAL 存在及未重放。因此 schema 可能不完整，
不可据此判定某张表不存在。不可读数据库输出 `encrypted_or_unknown`，不猜测
算法。整个检查通过子进程限时，避免文件访问挂起使诊断无限等待。

测试覆盖：不泄露行内容与会话表后缀、源文件不变化、WAL 不变化且明确标记
未读取、未知/空文件头、路径缺失。4 项测试通过。

## 继续实施所需步骤

1. 已完成本机目录复查：16 个相关数据库均无法直接按标准 SQLite 读取。
2. 对加密库建立可复现的本地解密读取方式，验证页完整性及数据库一致性。
   读取目录的授权不等于已经拥有数据库密钥。系统安全设置调整或微信重签名
   尚未执行；若某条方案依赖这些操作，需单独评估后再选择。
3. 用联系人/群名、资源索引和真实文件交叉验证，覆盖图片、视频、普通附件、
   同名不同文件、转发至多个会话以及多账号。名称优先考虑备注，其次群名/昵称，
   再回退为会话 ID；名称不是唯一标识。
4. 验证成功后接入扫描与分页流程。一个文件可能关联多个会话，新增带账号
   作用域的多值关联模型，而非把多个来源强行合成一个 `conversationName`。
   保留旧 manifest 解码兼容性，明确展示未授权、未解密、未找到引用等状态。

关联信息用于展示、搜索与分组，不应改变现有归档/释放的完整性判断。

## 管理员探测结果与下一项实验

用户在本机终端运行 `check-wechat-process-access.sh --admin`，仍返回
`task_for_pid: 5 ((os/kern) failure)`。签名检查显示当前官方微信启用了
Hardened Runtime（`flags=0x10000(runtime)`）。这些事实符合进程调试保护
限制的表现，但返回码本身不能唯一定位到 SIP、签名或调试授权中的某一项。
重复 sudo 或目录授权没有新的验证价值。

社区项目明确采用“退出微信 → ad-hoc 重签名 → 管理员运行扫描器”的 Mac
路径：[上游 README](https://github.com/raclen/wechat-suite/blob/main/wechat-decrypt/README.md)。
这不是已在本机 4.1.11 验证成功的办法，也不属于普通文件读取。

下一项可选实验的具体边界（尚未执行，需用户接受对安装程序的改动）：

1. 记录当前微信签名与版本，备份完整官方应用并验证备份签名；备份失败则停止。
2. 用户完成当前微信操作后正常退出微信；避免强制结束进程。
3. 对微信应用作临时 ad-hoc 重签名，再启动和登录；可能产生权限提示或登录变化。
4. 先重跑进程访问探测；成功后才进入最小范围的数据库密钥与完整性验证。
5. 实验结束退出微信，从已验证的备份还原官方应用并复核签名。不会通过还原
   程序覆盖聊天数据目录。启动微信本身仍会正常更新其数据，因此不宣称实验
   期间聊天数据库完全不变化。

本实验不包含关闭 SIP、导出全部聊天或上传数据。对独立应用副本重签名是否
能访问同一账号容器/钥匙串仍未验证，不能把复制 `.app` 等同于数据隔离。
产品的普通用户流程尚不能依赖这条研究路径。
