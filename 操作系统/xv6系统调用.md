# xv6系统调用

> 基于 xv6 的 Sandbox 实验：实现 interpose 系统调用，为进程添加"系统调用黑名单"功能。

## 一、系统调用概述

^syscall-overview

用户程序本身不能直接操作硬件、磁盘、文件系统，必须向内核发起"请求"——这就是系统调用（syscall）。

xv6 中常见的系统调用：

| 系统调用 | 作用 |
|----------|------|
| `open` | 打开文件 |
| `read` | 读取文件 |
| `write` | 写入屏幕/文件 |
| `fork` | 创建进程 |
| `exec` | 执行程序 |
| `exit` | 退出程序 |

### 系统调用路径（用户态到内核态）

^syscall-path

```
用户程序调用 open()
        ↓
进入 user/usys.S 里的 syscall stub
        ↓
执行 ecall 指令
        ↓
CPU 从用户态切换到内核态
        ↓
进入 kernel/trap.c
        ↓
进入 kernel/syscall.c 的 syscall()
        ↓
根据系统调用编号调用 sys_open()
        ↓
真正打开文件
```

## 二、Sandbox 任务概述

^sandbox-task

**任务名称：** Sandbox a command —— 把一个命令放进沙箱。

**新增系统调用：**

```c
interpose(mask, "-");
```

**作用：** 当前进程主动告诉内核："以后我不允许使用 mask 里指定的那些系统调用。"内核每次收到这个进程的系统调用请求时，先检查这个 syscall 是否在黑名单里，如果在就直接拒绝。

**示例：**

```bash
sandbox 32768 - cat README
```

结果输出：

```
cat: cannot open README
```

## 三、mask 与位图机制

### 位图概念

`mask` 是一个整数位图（bitmap），每一个二进制位代表一个系统调用。

假设系统调用编号：

```c
#define SYS_fork   1
#define SYS_exit   2
#define SYS_read   5
#define SYS_open   15
#define SYS_write  16
```

如果要禁止 `open`，就把第 15 位设为 1：

```c
1 << SYS_open       // = 1 << 15 = 32768
```

### 检查是否被禁止

^bit-check

```c
if (p->syscall_mask & (1 << num)) {
    // 该 syscall 在 mask 中被标记为 1 —— 即被禁止
}
```

**位运算解析：**
- `1 << 15` = 将数字 1 左移 15 位 = 二进制 `1000 0000 0000 0000` = 十进制 32768
- `mask & (1 << num)` 检查第 num 位是否为 1
- 结果非 0 表示该 syscall 被禁止

> 常见错误：`if ((p->syscall_mask & (1 << num)) == 0)` 是**反的判断**——它在第 num 位为 0 时拒绝，会导致所有正常 syscall 都失败！

## 四、需要修改的文件（完整清单）

一个系统调用从用户态到内核态的完整链路，需要修改以下文件：

### 第一类：让用户程序能调用 interpose

**user/user.h** —— 函数声明 ^user-h

```c
// 添加函数声明
int interpose(int, char *);
```

**user/usys.pl** —— 生成系统调用入口 ^usys-pl

```perl
# 添加
entry("interpose");
```

这个文件会生成 `user/usys.S`，其中使用 RISC-V 的 `ecall` 指令进入内核。

**kernel/syscall.h** —— 分配系统调用编号 ^syscall-h

```c
#define SYS_interpose 22  // 编号根据现有最大编号 + 1
```

用户态调用 `interpose()` 时，会把编号放进寄存器 `a7`。

### 第二类：让内核知道怎么处理 interpose

**kernel/syscall.c** —— 系统调用分发表 ^syscall-c

```c
// 添加 extern 声明
extern uint64 sys_interpose(void);

// 在分发表中添加
static uint64 (*syscalls[])(void) = {
    [SYS_fork]    sys_fork,
    [SYS_open]    sys_open,
    // ...
    [SYS_interpose] sys_interpose,
};
```

**kernel/sysproc.c** —— 内核实现 ^sysproc-c

```c
uint64
sys_interpose(void)
{
    int mask;
    char path[MAXPATH];

    argint(0, &mask);               // 取第 0 个参数 mask
    if (argstr(1, path, MAXPATH) < 0) // 取第 1 个参数 path
        return -1;

    myproc()->syscall_mask = mask;  // 保存到 proc 结构体
    return 0;
}
```

### 第三类：给进程添加 mask 字段

**kernel/proc.h** —— 进程结构体 ^proc-h

```c
struct proc {
    // ... 其他字段
    int syscall_mask;   // 系统调用黑名单（bitmap）
};
```

**kernel/proc.c** —— 初始化 mask ^proc-c-init

在 `allocproc()` 中初始化：

```c
p->syscall_mask = 0;  // 新进程默认不禁止任何系统调用
```

> 不加这一行，`syscall_mask` 可能是随机值，可能一启动就把 init 的系统调用禁掉，导致 `panic: init exiting`。

**kernel/proc.c** —— fork 继承 mask ^proc-c-fork

在 `fork()` 或 `kfork()` 中复制：

```c
np->syscall_mask = p->syscall_mask;
```

> 题目要求 mask should be inherited by children of fork。子进程必须继承父进程的 syscall 限制，否则被沙箱限制的程序可以 fork 出一个不受限制的子进程来绕过沙箱。

### 第四类：真正拦截 syscall（核心）

**kernel/syscall.c** —— 在 `syscall()` 中添加拦截逻辑 ^syscall-intercept

```c
void
syscall(void)
{
    int num;
    struct proc *p = myproc();

    num = p->trapframe->a7;  // 从 RISC-V 寄存器 a7 获取系统调用编号

    if (num > 0 && num < NELEM(syscalls) && syscalls[num]) {
        // 检查该 syscall 是否被当前进程 mask 禁止
        if (p->syscall_mask & (1 << num)) {
            p->trapframe->a0 = -1;  // 返回值设为 -1
            return;                  // 不执行系统调用
        }
        p->trapframe->a0 = syscalls[num]();  // 正常执行
    } else {
        printf("%d %s: unknown sys call %d\n",
               p->pid, p->name, num);
        p->trapframe->a0 = -1;
    }
}
```

## 五、关键寄存器说明

^registers

RISC-V 中系统调用相关寄存器：

| 寄存器 | 作用 |
|--------|------|
| `a7` | 存放系统调用编号 |
| `a0` | 存放第 1 个参数 / 返回值 |
| `a1` | 存放第 2 个参数 |
| `a2` | 存放第 3 个参数 |

在 xv6 内核中：
- `p->trapframe->a7` = 系统调用编号
- `p->trapframe->a0 = -1` = 将返回值设为 -1（表示失败）

## 六、为什么 fork 需要继承 mask 而 exec 不需要

^fork-exec-mask

**fork** 是创建新进程，所以**必须**复制限制：

```c
np->syscall_mask = p->syscall_mask;
```

**exec** 不是创建新进程。它只是**替换**当前进程的程序内容（代码、数据），但进程的 `proc` 结构体还在——pid 没变，`syscall_mask` 也没变。

这也是为什么：

```bash
sandbox 32768 - cat README
```

可以限制到 `cat`：子进程先 `interpose` 设限制，再 `exec` 成 `cat`，限制仍然存在。

## 七、完整执行流程

以 `sandbox 32768 - cat README` 为例：

^execution-flow

```
1. shell 读取命令: sandbox 32768 - cat README
2. shell fork 一个进程执行 sandbox
3. sandbox 进程: mask=32768, path="-", command="cat README"
4. sandbox 调用 fork 创建子进程
5. 子进程调用 interpose(32768, "-")
6. 用户态 interpose → ecall → 内核态
7. kernel syscall() 发现编号 = SYS_interpose
8. kernel sys_interpose() 保存: p->syscall_mask = 32768
9. 子进程 exec("cat", ...) → 变成 cat 程序
10. cat 想打开 README → 调用 open("README")
11. open → ecall → 内核态
12. syscall() 取: num = SYS_open
13. 内核检查: p->syscall_mask & (1 << SYS_open)
14. 32768 正好 = 1 << SYS_open, 检测到被禁止
15. 内核: p->trapframe->a0 = -1 (拒绝 open)
16. cat 发现 open 失败
17. cat 输出: "cat: cannot open README"
```

## 八、sandbox 程序逻辑

题目提供的 `user/sandbox.c` 逻辑：

```
读取命令行参数
    ↓
fork 出一个子进程
    ↓
子进程调用 interpose(mask, "-")
    ↓
子进程 exec 要被限制的命令
    ↓
父进程 wait 等子进程结束
```

参数解析（以 `sandbox 32768 - cat README` 为例）：

```
argv[0] = "sandbox"
argv[1] = "32768"
argv[2] = "-"
argv[3] = "cat"
argv[4] = "README"
```

## 九、验证与测试

^testing

手动测试：

```bash
# 禁止 open (mask = 1 << 15 = 32768)
sandbox 32768 - cat README
# 预期: cat: cannot open README

# 禁止 fork (mask = 1 << 1 = 2)
sandbox 2 - ls
# ls 无法 fork 子进程

# mask = 0 不禁止任何调用
sandbox 0 - cat README
# 预期: 正常显示 README 内容
```

## 十、Linux 中的对应概念

Linux 中类似机制叫 **seccomp** (secure computing mode)，也可以限制进程能调用哪些 syscall。xv6 的 `interpose` + `sandbox` 就是一个极简版的 syscall filter。

## 十一、相关笔记

- 操作系统进程管理（fork/exec 语义）
- 用户态与内核态切换机制（ecall/陷阱帧）
- xv6 内核编译与运行流程
