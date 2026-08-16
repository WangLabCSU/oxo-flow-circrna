# PR

## 1. 配置模板嵌套导致路径解析非确定性

**问题：**

原 `[config]` 里写了嵌套引用：

```toml
reference_dir = "/data/references/GRCh38"
reference_fasta = "{config.reference_dir}/genome.fa"   # 值里又引用了 reference_dir
gene_annotation = "{config.reference_dir}/genes.gtf"
circexplorer2_ref = "{config.reference_dir}/hg38_ref.txt"
ciriquant_config = "{config.reference_dir}/CIRIquant.yml"
```

规则 shell 用到 `{config.reference_fasta}`。oxo-flow 渲染时要完成两步替换：

- 把 `{config.reference_fasta}` 换成它的值 `{config.reference_dir}/genome.fa`
- 把 `{config.reference_dir}` 换成 `/data/references/GRCh38`

引擎是一次遍历、逐个键替换（`executor/process.rs` 的 `render_shell_command`），而遍历 HashMap 的顺序是随机的，导致两种结果：

| 替换顺序                                     | 过程                                                         | 最终渲染                                        |
| -------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------- |
| 先换 `reference_fasta`，再换 `reference_dir` | `{config.reference_fasta}` → `{config.reference_dir}/genome.fa`，随后 `{config.reference_dir}` → `/data/references/GRCh38` | `/data/references/GRCh38/genome.fa` ✓           |
| 先换 `reference_dir`，再换 `reference_fasta` | 原文里没有 `{config.reference_dir}` 可换（只有 `{config.reference_fasta}`），白换；第二步把 `{config.reference_fasta}` 换成原始值 | 残留字面量 `{config.reference_dir}/genome.fa` ✗ |

即：`reference_dir` 必须在所有依赖它的键**之后**替换才能成功，但顺序随机，同一份配置跑起来时好时坏。实测连跑 6 次，有时全部解析成功，有时一个都不解析——属非确定性 bug。

**修复：**

- 删除手写的 `reference_fasta` / `gene_annotation` / `circexplorer2_ref` / `ciriquant_config` 标准键——引擎在 `reference_dir` 存在时会自动推导这些路径的具体字符串（`config.rs` 的 `derive_reference_paths`），没有嵌套，一步到位。
- 规则里只直接引用 `{config.reference_dir}`（值就是字面量，无嵌套），单次替换必然命中；对引擎不自动推导的自定义文件（`hg38_ref.txt`），同样以 `{config.reference_dir}/hg38_ref.txt` 直接写在规则 shell 里。

> 如何从oxo-flow根治：
>
> `render_shell_command`（`executor/process.rs`）与 checkpoint 侧的 `expand_config_in_path`（`executor/checkpoint.rs`）都只做单遍替换，配置值内嵌 `{config.X}` 时解析顺序随机导致结果不确定。建议引擎把替换做成**迭代到不动点**（fixed-point），或先按依赖解析配置值再做规则替换，并对最终仍残留的 `{config.X}` 报错而非静默通过。



## 2. 跳过无关的 reference 构建

**问题：**

原配置没有显式 `[[references]]`，依赖引擎的 `with_derived_references`（`config.rs`）：只要设置了 `reference_dir` 且没有任何 `[[references]]` 块，引擎会一次性生成 **8 个** ReferenceDef（samtools_faidx、bwa、bwamem2、bowtie2、minimap2、star、hisat2、gatk_dict）。本流程实际只用 bowtie2、STAR、bwa、hisat2（find_circ 用 bowtie2，circRNA_finder 用 STAR，CIRIquant 与 circexplorer2 用 bwa，CIRIquant 用 hisat2），其余 4 个（samtools_faidx、bwamem2、minimap2、gatk_dict）属于无关构建；若用户目录里恰好缺其中某个文件，首次运行会被迫去构建它。

**修复：**

在 `circrna.oxoflow` 显式声明 `bowtie2_index`、`star_index`、`bwa_index`、`hisat2_index` 四个 `[[references]]` 块。显式声明即抑制自动生成的 8 个。引擎对每个 reference 检查输出文件是否存在：已存在直接复用（真实 run 已实测四个都跳过，无任何 build 日志），缺失才执行 `build`。

> 如何从oxo-flow根治：
>
> `with_derived_references` 无法表达"本流程只需要其中某几个索引"。可考虑按规则 shell 中实际引用的 `{config.X}` 键反推所需 reference，或允许配置按名选装。



## 3. 用户只需改一个 `reference_dir`

**问题：**

原配置的设计意图本就是"只改 `reference_dir`"，但它把推导出的路径**手写**在配置值里：

```toml
reference_fasta = "{config.reference_dir}/genome.fa"
gene_annotation = "{config.reference_dir}/genes.gtf"
circexplorer2_ref = "{config.reference_dir}/hg38_ref.txt"
ciriquant_config = "{config.reference_dir}/CIRIquant.yml"
```

有两个问题：

1. **冗余**：这些正是引擎 `derive_reference_paths` 会自动推导的路径，手写一遍属重复。
2. **不可靠**：手写值全部用了嵌套模板 `{config.reference_dir}/...`，受第 1 节的单遍随机替换影响，时好时坏。

**修复：**

- `[config]` 只保留 `reference_dir = "reference"`，无任何绝对路径。
- 引擎自动推导 `reference_fasta`、`gene_annotation`、`bowtie2_index`、`bwa_index`、`hisat2_index`、`star_index` 等全部路径。
- 为目录布局不同的用户，保留了注释掉的绝对路径覆盖示例（`reference_fasta = "/path/genome.fa"` 等），取消注释即可按需覆盖单个路径。
- `reference_dir/` 预期布局（各调用方所需文件）：`genome.fa`、`genes.gtf`、`hg38_ref.txt`、`bowtie2/`、`bwa/`、`hisat2/`、`star/`。已有索引不重建，缺失才自动构建。



## 4. CIRIquant 配置：路径不一致 + 裸命令名 + 索引路径不符

**问题：**

原版 CIRIquant 配置链路存在三处问题：

1. **配置文件不存在**：`circrna.oxoflow` 里 `ciriquant_config = "{config.reference_dir}/CIRIquant.yml"`（且是嵌套模板，受第 1 节随机替换影响），规则 `--config {config.ciriquant_config}` 指向 `reference_dir/CIRIquant.yml`。但没有任何机制会在该路径生成此文件——仓库里唯一的生成代码 `scripts/generate_ciriquant_config.py` 产出的是另一个路径 `config/ciriquant_hg38.yml`（其所在 setup.sh 也已随 README 改版废弃）。CIRIquant 找不到配置文件。
2. **裸命令名**：`scripts/generate_ciriquant_config.py` 生成的 yml 写 `bwa: bwa` 等裸命令名。CIRIquant 的 `check_config`（`.../CIRIquant/utils.py:44-51,79-82`）用 `os.path.exists()` 校验工具路径、**不查 PATH**，启动即报 `File: bwa, not found`。且 4 个工具只在 conda env `ciriquant` 内、系统 PATH 上没有，必须在规则执行、env 已激活后用 `command -v` 解析。
3. **索引路径不符**：生成脚本把 `bwa_index` / `hisat_index` 都写成 `reference_dir/genome.fa`，而 CIRIquant 会拼后缀检查 `genome.fa.bwt` / `genome.fa.1.ht2`（`utils.py:95,100`）；实际索引位于引擎推导的 `reference/bwa/genome.fa`、`reference/hisat2/genome.fa`，顶层没有这两个文件 → 同样 ConfigError。

原版 `ciriquant` 规则对失败是宽容的（输出缺失只打 WARNING 不 exit），所以这些问题不会让流程崩溃，而是**静默地导致 CIRIquant 不产出结果**。

**修复：**

改为不再依赖共享配置文件，`ciriquant` 规则在每个样本自己的输出目录内联生成 `results/{sample}.CIRI/ciriquant.yml`：

- 4 个工具用 `command -v` 解析绝对路径（env 激活后必然命中）；
- 参考路径用引擎推导的 `{config.reference_fasta}` / `{config.gene_annotation}` / `{config.bwa_index}` / `{config.hisat2_index}`；
- 每次运行都取当前 `[config]` 值，不存在共享 yml 被 checkpoint 标记跳过而过期的问题。

同时删除 `circrna.oxoflow` 里的 `ciriquant_config` 配置键，不再依赖共享配置文件；`scripts/generate_ciriquant_config.py` 与 setup.sh（本就随 README 改版废弃）不再是流程依赖。



## 5. reference/ 目录结构与引擎推导路径对齐

**问题：**

引擎推导 `bwa_index = reference/bwa/genome.fa`、`hisat2_index = reference/hisat2/genome.fa`、`bowtie2_index = reference/bowtie2/genome.fa`、`star_index = reference/star`。若目录布局不符（例如把 bwa/hisat2 索引平铺在 `reference/` 顶层），`config show` 推导出的路径就对应不上真实文件，运行期报文件不存在。

**修复：**

- `reference_dir/` 下的目录布局必须与推导路径一一对应，用软链把用户自己的参考数据组织成如下结构即可：

  ```
  reference_dir/
  ├── genome.fa
  ├── genome.fa.fai
  ├── genes.gtf
  ├── hg38_ref.txt
  ├── bowtie2/genome.fa.{1,2,3,4,rev.1,rev.2}.bt2
  ├── bwa/genome.fa.{bwt,pac,ann,amb,sa}
  ├── hisat2/genome.fa.{1-8}.ht2
  └── star/
  ```

- `.gitignore` 加入 `reference/`（用户参考数据不入库）。



## 6. reference 构建缺工具时不能自动安装

**问题：**

reference 构建命令（如 `bowtie2-build`、`bwa-mem2 index`）假设工具已装在当前环境，引擎只负责执行命令，不会自动安装。工具缺失时 run 以 `command not found`（exit 127）中止——虽然报错里能看出缺的是哪个工具，但引擎不会帮你装，用户得手动装好才能重跑。

**修复（流程侧）：**

本流程显式声明 `[[references]]` 且索引文件已存在，构建不会触发，绕开了对无关工具的依赖；但若用户确实缺索引又缺工具，仍要手动装好工具才能跑。

> 对引擎的建议：
>
> 给 reference 构建加环境支持：构建命令可声明所需工具，在指定 conda/pixi 环境中执行（与规则的环境机制一致），让 `oxo-flow` 在首次构建前自动建好环境，而不是要求用户手工安装。



## 7. CIRCexplorer2 的 bwa mem 用错索引路径

**问题：**

circexplorer2 规则先用 `bwa mem` 把 reads 比对到参考基因组，未比上的部分再交给 CIRCexplorer2 parse 找环。原规则把 `{config.reference_fasta}`（`reference/genome.fa`，是 fasta 文件本身）传给 `bwa mem`，但 `bwa mem` 需要的是**索引前缀**，而 bwa 索引实际在 `reference/bwa/genome.fa`。bwa 去 `reference/` 下找不到索引（`[E::bwa_idx_load_from_disk] fail to locate the index files`），产出空 SAM，CIRCexplorer2 parse 随即失败（`file does not contain alignment data`），整个流程中止。

**修复：**

`bwa mem` 的参数从 `{config.reference_fasta}` 改为 `{config.bwa_index}`（即 `reference/bwa/genome.fa`），与 bwa 索引实际位置一致（`bwa mem` 需要索引前缀，不能用 fasta 路径）。