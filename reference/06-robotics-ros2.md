# ROS 2、感知与导航

凡本文出现带 `待核实` 的包名 / 可执行名 / Topic 名 / frame 名，一律以 `ros2 pkg list`、`ros2 topic list`、`ros2 interface show`、厂家驱动仓库 README 为准，不得照抄本文示意名。

## 是什么与为什么

ROS 2（Robot Operating System 2）不是操作系统，而是**分布式进程通信中间件 + 机器人约定**：把"读传感器、算位姿、规划路径、控制电机"拆成独立进程（Node，节点），用统一接口在进程与机器间传数据。它解决的问题是：机器人软件必然多语言（Python 做算法验证、C++ 做实时控制）、多进程、多机（机载算力单元 + 上位机 + 遥控端），若每模块自己写 socket，接口与调试成本会失控。

### 六种机制：先选对，再写代码

| 机制 | 语义 | 谁发布 / 谁订阅 | 频率量级 | QoS 要点 | 启动顺序 |
|---|---|---|---|---|---|
| Topic（话题） | 单向异步、多对多数据流 | 驱动/感知发布，算法订阅，可多订阅者 | 10–100 Hz；IMU 可达 1 kHz | 传感器 BEST_EFFORT；控制/状态 RELIABLE；depth 要小 | 发布者可先起，订阅者后起仍能收后续数据 |
| Service（服务） | 同步请求-响应，一问一答 | 客户端请求，服务端应答 | 事件触发，非周期 | 默认 RELIABLE | 服务端必须先起，否则请求立即失败 |
| Action（动作） | 长任务：目标 + 周期反馈 + 结果 + 可取消 | 客户端提交目标，服务端执行 | 反馈 1–10 Hz | RELIABLE；必须处理取消与抢占 | 服务端先起；客户端要设超时 |
| Parameter（参数） | 节点级配置，运行时可声明与读写 | 节点自持，外部 `ros2 param` 读写 | 事件触发 | 参数回调里别做重活 | 启动时声明，否则读到默认值 |
| Launch（启动文件） | 编排多节点、参数、命名空间、延时 | `ros2 launch` 拉起 | — | — | **"启动顺序"唯一可靠的实现手段** |
| Lifecycle（生命周期节点） | `unconfigured→inactive→active→finalized` 受控状态机 | 外部触发状态迁移 | — | 迁移失败要有日志与安全回退 | 上游 `on_activate` 成功后再拉下游 |

选型规则：连续数据流用 Topic；"查状态/切一次模式"用 Service；"导航到某点、回充、执行一段步态"用 Action。把长任务塞进 Service 会让调用方阻塞并误判超时。

### DDS 与 QoS：最容易被忽略、也最容易致命的一层

底层由 DDS（Data Distribution Service，数据分发服务）实现发现与传输，默认 RMW 为 `rmw_fastrtps_cpp`，也可换 Cyclone DDS。QoS（Quality of Service，服务质量）是发布者与订阅者之间的**契约**：不兼容就不连接，而且**不报错**，只表现为"收不到数据"。必须记住：`RELIABLE`（重传，适合控制指令、状态、地图、代价地图）、`BEST_EFFORT`（丢帧不重传，适合 LiDAR/相机/IMU 等高频大数据）、`TRANSIENT_LOCAL` + RELIABLE（**为后加入的订阅者保留最后 N 条**，地图、机器人描述、静态 TF 必须用它）、`KEEP_LAST(depth)`（默认 10，太大会积压延迟，太小会丢关键帧）、`deadline` / `liveliness`（判断对端是否活着，是失联保护的基础；超时按控制周期定，例如 100 ms 控制周期给 300 ms 失联判定 = 3 个周期）。

排查：`ros2 topic info <topic> --verbose` 对比两端 reliability/durability；`ros2 doctor` 看发现层；跨机不通先查 `ROS_DOMAIN_ID`、网段与组播。日常定位"看起来在跑但不对"的五条命令：`ros2 node list`、`ros2 topic hz <topic>`、`ros2 topic delay <topic>`、`ros2 run tf2_tools view_frames`、`ros2 param dump <node>`。

### TF2 与 URDF：几何关系的唯一真相源

URDF（Unified Robot Description Format）用 XML 描述连杆（link）、关节（joint）、惯性、碰撞体、可视化网格，回答"雷达相对机体装在哪、朝哪"。TF2 把 URDF 的静态变换与运行时动态变换（里程计、定位）组织成一棵**树**，任何节点直接查询"B 在 A 坐标系下的位姿"，不必自己推导。标准链是 `map → odom → base_link → 各传感器 link`：`map → odom` 由定位（AMCL / SLAM / LIO 类方案）发布，处理全局校正；`odom → base_link` 由里程计或状态估计发布，连续、短期准、会漂移；`base_link → sensor_link` 由 URDF + `robot_state_publisher` 发布。铁律：**同一对父子坐标系只能有一个发布者**，否则 TF 抖动、RViz 报多父警告。

### 完整数据链路

```
传感器（LiDAR / 深度相机 / RGB / IMU / 超声 / 编码器）
  └─ 驱动节点：封装厂家 SDK，私有协议 → 标准消息
      └─ ROS Topic：sensor_msgs/*，BEST_EFFORT，带 stamp + frame_id
          ├─ 滤波与预处理：点云滤波 / 图像处理 / IMU 预处理
          ├─ 里程计与状态估计：融合 IMU + 轮式/足式里程计 + LiDAR
          └─ SLAM / 定位 → map、TF、代价地图（TRANSIENT_LOCAL）
              └─ 全局路径规划 0.1–1 Hz → 局部避障与轨迹 10–20 Hz
                  └─ 运动控制（速度指令 Topic 或 Action）
                      └─ 厂家 SDK / 下位机（UDP/TCP/CAN）→ 关节电机、步态控制器、真机
```

每往下一层，频率降低、延迟敏感度升高：感知几十 Hz、规划 1 Hz 级、控制 100 Hz–1 kHz 级。接口分层的意义就在于**按层设超时与降级**，别让 1 Hz 的规划阻塞 100 Hz 的控制。

## 最小可运行示例

**依赖与版本假设**：Ubuntu 24.04 + ROS 2 Jazzy（Python 3.12），或 Ubuntu 22.04 + ROS 2 Humble（Python 3.10）；**具体发行版与可用包以官方文档为准（`待核实`）**；已装 `ros-<distro>-desktop`（含 rclpy、rviz2、tf2_tools、rosbag2）；终端先执行 `source /opt/ros/<distro>/setup.bash`（Bash）。Windows 侧用 WSL2 跑 ROS 2，PowerShell 只做 SSH 与文件传输。

### 最小 publisher / subscriber（Python / rclpy）

`~/ros2_ws/src/demo_minimal/demo_minimal/talker.py`：

```python
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import LaserScan        # 仅作消息类型示例，实际按传感器替换

class Talker(Node):
    def __init__(self) -> None:
        super().__init__("demo_talker")
        # 传感器数据流用 BEST_EFFORT；改成 RELIABLE 会在弱网下积压
        qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                         history=HistoryPolicy.KEEP_LAST, depth=5)
        self.pub = self.create_publisher(LaserScan, "/demo/scan", qos)
        self.timer = self.create_timer(0.1, self.tick)      # 10 Hz

    def tick(self) -> None:
        msg = LaserScan()
        msg.header.stamp = self.get_clock().now().to_msg()  # 时间戳必须用节点时钟
        msg.header.frame_id = "lidar_link"                 # 必须与 URDF/TF 一致
        msg.angle_min, msg.angle_max = -3.14159, 3.14159
        msg.angle_increment = 0.0087                        # 约 0.5°
        msg.range_min, msg.range_max, msg.ranges = 0.1, 30.0, [1.0] * 720
        self.pub.publish(msg)

def main() -> None:
    rclpy.init(); node = Talker()
    try:
        rclpy.spin(node)          # 生产写法：spin 放 try 里，Ctrl+C 走 finally 清理
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node(); rclpy.shutdown()

if __name__ == "__main__":
    main()
```

`listener.py` 结构与 `talker.py` 相同，用**完全相同**的 QoS 订阅 `/demo/scan`，`main()` 照抄上面只换成 `Listener()`：

```python
class Listener(Node):
    def __init__(self) -> None:
        super().__init__("demo_listener")
        qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                         history=HistoryPolicy.KEEP_LAST, depth=5)
        self.create_subscription(LaserScan, "/demo/scan", self.on_scan, qos)
        self.count = 0

    def on_scan(self, msg: LaserScan) -> None:
        self.count += 1
        if self.count % 50 == 0:      # 每 5 s 打一次日志，高频话题禁止逐帧打印
            self.get_logger().info(f"frame={msg.header.frame_id} n={len(msg.ranges)}")
```
验收（Ubuntu Bash，两个终端）：`ros2 run demo_minimal talker` 与 `ros2 run demo_minimal listener`；`ros2 topic hz /demo/scan` 应接近 10 Hz；`ros2 topic info /demo/scan --verbose` 两端 reliability 必须一致。

### 最小 launch（Python 版，编排启动顺序）

`launch/bringup.launch.py`：

```python
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, TimerAction, IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare

def generate_launch_description() -> LaunchDescription:
    use_sim_time = LaunchConfiguration("use_sim_time")
    sensor_driver = Node(                      # 1) 传感器驱动最先
        package="<lidar_driver_pkg>",          # 待核实：以厂家仓库 README 为准
        executable="<lidar_node>",             # 待核实
        name="lidar_driver", output="screen",
        parameters=[{"frame_id": "lidar_link"}],   # 参数名 待核实
    )
    state_estimation = Node(                   # 2) 状态估计：等传感器与 TF 就绪
        package="<state_estimation_pkg>", executable="<ekf_node>",   # 待核实
        name="state_estimation", output="screen",
        parameters=[{"use_sim_time": use_sim_time}],
    )
    navigation = IncludeLaunchDescription(      # 3) 导航栈最后起
        PythonLaunchDescriptionSource(PathJoinSubstitution(
            [FindPackageShare("<nav_pkg>"), "launch", "<nav_bringup>.launch.py"])),  # 待核实
        launch_arguments={"use_sim_time": use_sim_time, "autostart": "true"}.items(),
    )
    return LaunchDescription([
        DeclareLaunchArgument("use_sim_time", default_value="false"),
        sensor_driver,
        # 固定延时是最简顺序控制；更稳的做法是上游 on_activate 成功后再拉下游
        TimerAction(period=5.0, actions=[state_estimation]),
        TimerAction(period=8.0, actions=[navigation]),
    ])
```

验收：`ros2 launch demo_bringup bringup.launch.py use_sim_time:=false`；`ros2 node list && ros2 topic list`；`ros2 run tf2_tools view_frames` 生成 frames.pdf，确认无多父、无断链。启动顺序三条通用规则：**① 静态 TF 与 `robot_state_publisher` 最先；② 传感器驱动次之；③ 依赖地图/定位的规划与控制最后**。任何一级起不来先修它，不要让下游带空数据跑。

## 工程实现要点

### 传感器：谁发布、谁订阅、频率、坐标系、QoS、启动阶段

| 传感器 | 消息类型（标准） | 发布者 → 订阅者 | 频率量级 | frame_id | QoS 要点 | 启动阶段 |
|---|---|---|---|---|---|---|
| LiDAR（机械/固态） | `LaserScan`（2D）或 `PointCloud2`（3D） | 驱动 → SLAM、代价地图、RViz | 10–20 Hz，单帧数万至十几万点 | `lidar_link`（`待核实`） | BEST_EFFORT + 小 depth | 第 2 阶段 |
| 深度 / RGB 相机 | `Image` + `CameraInfo` + `CompressedImage` + `PointCloud2` | 驱动 → 感知/避障、图传、RViz | 深度 15–30 Hz，RGB 可达 30 Hz | `camera_link` / `camera_depth_optical_frame`（`待核实`） | 各流独立 QoS；图像大，勿用 RELIABLE | 第 2 阶段 |
| IMU | `Imu` | 驱动 → 状态估计、SLAM、运控 | 100–1000 Hz | `imu_link` | depth 要小（高频） | 第 2 阶段，须早于状态估计 |
| 超声波 | `Range` | 驱动 → 近距避障/安全层 | 10–50 Hz | `sonar_*_link`（`待核实`） | RELIABLE；失效必须对上层可见 | 第 2 阶段 |
| 编码器 / 里程计 | `Odometry` | 驱动或状态估计 → SLAM、定位、TF | 50–200 Hz | 发布 `odom → base_link` | RELIABLE + 小 depth；**TF 只能一个发布者** | 第 2 阶段，早于定位 |

选型的现实约束（规格以厂家数据手册为准 `待核实`）：固态 LiDAR 视场角窄但点云密，机械旋转式视场完整但结构脆弱；深度相机近距好、强光下失效；超声抗干扰但精度低。真实项目必须冗余：LiDAR + IMU 做定位，超声/深度做近距安全兜底。

### 点云滤波、时间同步、标定

**点云链路**固定为 `PointCloud2（原始）→ 体素降采样 → 直通/半径/统计离群点滤波 → 地面分割 → 聚类/特征提取 → 定位或避障`：体素降采样把点数降到可实时处理的量级，**参数直接决定 CPU 占用**；直通滤波按高度/距离裁掉地面与远处噪声；统计离群点滤波去散粒噪声，代价是一次 K 近邻搜索；地面分割（RANSAC 平面或栅格高度差）是四足避障的关键一步；输出始终保持 `frame_id` + `stamp`，**滤波节点不得擅自改 frame_id**。

**时间同步**涉及四种时间：节点时钟（`use_sim_time` 决定用系统时间还是 `/clock`）、消息 `stamp`、接收时间、TF 查询时间。所有节点必须统一 `use_sim_time`，混用会导致 TF 查询报 "extrapolation into the past/future"。融合前必须时间对齐：硬件触发/PPS 同步优于软件近似；软件侧用 `message_filters` 的 `ApproximateTimeSynchronizer`，并显式写明最大允许时间差（例如 50 ms，依据是 IMU 100 Hz 的周期量级）。查 TF 用"最新可用时间"而非系统时间，否则跨机时钟偏差直接报错。**标定**分三类，各自的验收标准不同：内参（相机焦距/畸变 → 内参矩阵与畸变系数，写入 `CameraInfo` 或参数文件；验收是复标参数离散度小、去畸变后直线是直线）；外参（传感器相对机体位姿 → 写入 URDF/TF；验收是点云投影到图像边缘对齐，或直行时地面点云水平）；时间标定（补偿传感器间时间偏移，验收是运动点云无"拖影错层"）。标定文件纳入版本管理，文件头写标定日期、设备编号、工具与残差指标；换设备、碰撞后必须重标。

### 融合、SLAM、定位与 Nav2

**传感器融合与状态估计**：输入是 IMU（高频、有漂移）、编码器里程计（低频、打滑时失效）、LiDAR/视觉里程计（中频、累积误差小但会跳变）；输出是连续的 `odom → base_link` TF 与 `Odometry`，全局定位再给 `map → odom`。常见实现是 EKF/UKF 或因子图优化，过程噪声与观测噪声必须按**实测噪声**设置，不能照抄示例值。验收：静止 30 s 位移 < 0.05 m、航向 < 1°；推着走一圈回起点，闭环误差可量化。

**SLAM** 同时建图与定位：订阅点云 + IMU + 里程计，发布栅格/点云地图、`map` 话题与 `map → odom`。地图是低频大对象，**必须 `TRANSIENT_LOCAL`**。建图完成保存静态地图，转入"已知地图 + 纯定位"更稳定（具体算法与包名 `待核实`）；纯定位把激光/点云与地图匹配，输出位姿与 `map → odom` 校正。

**Nav2** 典型由规划服务器、控制服务器、行为树导航器、代价地图层、恢复行为组成（节点与插件名以官方文档为准 `待核实`）。数据接口：定位给位姿 → 全局规划出路径 → 局部控制器结合代价地图与实时障碍输出速度指令；导航目标用 Action 下发，速度用 Topic 输出。三组参数必须按真机调：机器人几何（半径/轮廓，依据 URDF 实测）、代价地图层（膨胀半径、障碍层来源）、控制器限制（最大线速度/角速度/加速度）；速度上限先从**保守值的 30%** 起步，按分级安全门禁逐级放开。**动态避障**靠局部代价地图的障碍层，要点是"感知到 → 标记 → 绕行 → 清除标记"的时序，障碍存活时间过短会来回抖、过长会记住已走开的障碍。**失败路径**：目标不可达触发恢复行为（清代价地图、原地旋转、后退）；定位丢失必须停并进安全状态，不允许"猜着走"。

### 调试、回放、部署

```bash
ros2 topic hz /<sensor_topic>            # 实测频率，差一个量级说明驱动或带宽有问题
ros2 topic delay /<sensor_topic>         # 端到端延迟，感知链路超 200 ms 就要查
ros2 run tf2_tools view_frames           # TF 树导出 PDF
ros2 bag record -o run1 /<topic_a> /<topic_b>   # 只录需要的，全录会打满磁盘
ros2 bag info run1 && ros2 bag play run1 --clock   # info 看条数/丢帧；回放必须配 --clock
```

机载单元上先看 CPU 与内存，点云与视觉最吃资源；频率下降、延迟上涨是过载的先行指标。机载与上位机之间要**降带宽**：只传降采样点云、压缩图像，必要时用 `image_transport` 类插件（`待核实`）。RViz 是"数据对不对"的第一现场，看之前先把 Fixed Frame 设成有发布者的坐标系（通常是 `map` 或 `odom`）；rosbag 是感知导航最重要的工程习惯——把真实运行录成包，之后所有算法迭代都在包上做，不再反复上真机。

### 学习写法 vs 生产写法

1. **QoS**：初学者全用默认（RELIABLE + KEEP_LAST(10)），小数据量没问题；企业按数据性质分档——传感器 BEST_EFFORT、控制/地图 RELIABLE、地图与静态 TF 加 TRANSIENT_LOCAL。原因：默认值在弱网与高频大数据下会积压甚至拖垮整机。
2. **节点粒度与异常处理**：初学者把读传感器、算位姿、发指令写在一个节点里，用 `while True: 处理()`；企业按单一职责拆分并保证独立可重启（感知崩溃不能带走控制，控制崩溃不能让机器人失控），用 Lifecycle 节点 + 参数校验 + 心跳检测 + 明确降级动作（收不到指令就零速或保持位置）。原因：故障隔离，且真机要求出错时行为是安全的而不是未知的。

## 常见坑与验收标准

- 订阅者收不到数据但发布者 `ros2 topic hz` 正常：**QoS 不兼容**或 `ROS_DOMAIN_ID` 不一致。先跑 `ros2 topic info <topic> --verbose` 对比 reliability/durability。
- TF 报 "extrapolation into the future"：`use_sim_time` 不统一，或查询用了系统时间；回放 bag 时 TF 乱也是同一原因，忘了 `--clock` 或忘了把节点 `use_sim_time` 设为 `true`。
- RViz 中点云/机器人整体偏移或不动：Fixed Frame 选错，或 `map → odom` 没有发布者（只有 `odom → base_link`）。
- 地图在 RViz 可见、`ros2 topic echo` 却是空：地图用 `TRANSIENT_LOCAL`，`echo` 默认 QoS 不匹配，加 `--qos-durability transient_local` 再看。
- 靠 `sleep` 硬等节点顺序：短暂可用，长期必须换 Lifecycle 状态迁移或显式就绪检测（等某 Topic 出现第一帧再起下游）。
- 拿真机直接试新参数并高速运行：违反分级门禁。参数改动先在仿真或 bag 回放上验证，再低速上真机。另需注意：两条链路同时发布 `odom → base_link`（驱动与状态估计各发一份）会让 TF 抖动、定位漂移，日志里还不容易发现。

验收标准（每条都能给出证据）：① 不看笔记画出数据链路图，标注每段的 Topic、消息类型、频率量级、坐标系、QoS；② 自己写的一对 publisher/subscriber 跑通，用 `ros2 topic hz` 与 `ros2 topic info --verbose` 证明频率正确、QoS 匹配；③ 用 Python 写一个 launch 让三个节点按正确顺序起来，故意反序启动能解释现象并说明 launch 为什么能解决；④ 用 `view_frames` 导出的 PDF 指认每条 TF 边的发布者，说清 `map → odom → base_link` 各由谁维护；⑤ 录一段不少于 60 s 的 bag（含 LiDAR + IMU + 里程计），离线回放跑通一次定位或 SLAM 并给出漂移的量化数字；⑥ 独立完成一次"传感器接不上"的排查（现象 → 可能原因 → 验证命令 → 结果判断 → 修复），并讲清一次 QoS 不匹配的失败案例：改哪一端、为什么不能随便改发布端；⑦ 说出至少三条机器人运动前的安全前置条件（仿真验证、速度限制、失联行为、急停可用）并说明如何验证它们真的生效。

## 学习路径

前置知识（缺了先补）：Linux/Ubuntu 命令行与进程管理、Python 基础与虚拟环境、坐标系与旋转（欧拉角、四元数）、C++ 基础（读 Nav2 等 C++ 实现时需要）、UDP/TCP 与网络基础。

1. **基础通信与坐标系**（2–3 周）：建 workspace、写 pub/sub、跑 Service 与 Action、改参数、写 launch；再学 URDF、TF2、RViz、`view_frames`。里程碑：能独立调试"收不到数据"，能给自拼机器人建 URDF 并在 RViz 正确显示。
2. **传感器接入**（2 周）：LiDAR/相机/IMU 驱动、`PointCloud2`、滤波、时间同步、标定。里程碑：点云与图像对齐，bag 可回放。
3. **状态估计与 SLAM**（2–3 周）：融合、建图、保存地图、纯定位。里程碑：闭环误差可量化，漂移在可接受范围。
4. **导航与避障**（2–3 周）：Nav2 规划/控制/代价地图、恢复行为、动态避障。里程碑：仿真中完成带动态障碍的往返导航。
5. **安全与真机**（持续）：分级门禁、失联保护、急停、日志与 bag 复盘。里程碑：真机低速完成完整"建图 → 定位 → 导航 → 停止"并可全程回溯。

每阶段结束自查三问：这个模块的输入/输出/失败行为分别是什么？频率和坐标系对不对？我能只看日志和 bag 就定位它的问题吗？三问都答得上才算"能独立做"，否则仍是"在学"。
