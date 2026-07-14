
# mount disks

unmounted_disks=$(lsblk -n -o NAME,TYPE,SIZE,MODEL,MOUNTPOINT | grep 'disk' | grep -v 'MOUNTPOINT' | grep 'EC2 NVMe Instance Storage' | awk '{print$1}')
sudo yum install lvm2 -y
mkdir -p /home/ubuntu/project
count=$(echo "$unmounted_disks" | wc -l)
unmounted_disks=($unmounted_disks)
disks_with_prefix=()
for disk in "${unmounted_disks[@]}"; do
    disks_with_prefix+=("/dev/${disk}")
done
for disk in "${disks_with_prefix[@]}"; do
    echo "正在创建物理卷: $disk"
    sudo pvcreate "$disk"
done
if [ "$count" -gt 1 ]; then
    sudo vgcreate group "${disks_with_prefix[@]}"
    sudo lvcreate -l 100%FREE -n volunm group
    sudo mkfs.ext4 /dev/group/volunm
    sudo mount /dev/group/volunm /home/ubuntu/project
    sudo chown ubuntu:ubuntu /home/ubuntu/project
    echo "已挂载多个磁盘"
else
    sudo vgcreate group "${disks_with_prefix[@]}"
    sudo lvcreate -l 100%FREE -n volunm group
    sudo mkfs.ext4 /dev/group/volunm
    sudo mount /dev/group/volunm /home/ubuntu/project
    sudo chown ubuntu:ubuntu /home/ubuntu/project
    echo "已挂载单个磁盘"
fi

# conda
# 1. 获得最新的miniconda安装包；
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh

# 2. 安装到自己的HOME目录下software/miniconda3中，这个目录在安装前不能存在，否则会报错；
sh Miniconda3-latest-Linux-x86_64.sh -b -p ${HOME}/software/miniconda3

# 3. 安装成功后可以删除安装包，节省存储空间
rm -f Miniconda3-latest-Linux-x86_64.sh

# 4. 将环境变量写入~/.bashrc文件中；(下面这句话，添加到~/.bashrc文件中)
export PATH=${HOME}/software/miniconda3/bin:$PATH

# 5. 退出重新登录或者执行以下命令，即可导入 conda 环境
source ~/.bashrc

# 6. 检查是否安装成功
conda --version
# 需要bin/conda激活环境
conda create -n yu-skills -y
# 创建一个新的conda环境，命名为myenv，并安装fastp
conda install -c conda-forge -c bioconda -c defaults kraken2 awscli bowtie2=2.5.5 megahit=1.2.9 diamond=2.2.3 checkv=1.1.1 genomad=1.12.0 fastp=1.3.3 seqkit cd-hit mafft
# fastp参数
fastp \
  -i R1.fq.gz -I R2.fq.gz \
  -o clean_R1.fq.gz -O clean_R2.fq.gz \
  --detect_adapter_for_pe \
  --cut_front --cut_tail \
  --cut_window_size 4 \
  --cut_mean_quality 20 \
  -q 20 \
  -u 30 \
  -n 5 \
  -l 50 \
  -x \
  -h fastp.html \
  -w 16


## 去除rRNA

bowtie2-build --threads 50 ${db}/arb_db.fasta.gz ${db}/arb_db/arb_db
bowtie2 --sensitive -x ${db}/arb_db/arb_db \
    -1 ${results_prinseq}/${Sample}_good_out_R1.fastq \
    -2 ${results_prinseq}/${Sample}_good_out_R2.fastq \
    --un-conc ${results_rRNA}/${Sample}_non_rRNA_reads.fastq \
    -S ${results_rRNA}/${Sample}_rRNA_mapped.sam \
    -p 50 > ${results_rRNA}/${Sample}_bowtie2.log
    #未匹配 rRNA 的双端 reads（即非 rRNA reads
done

#megahit
megahit -1 ${results_rRNA}/${Sample}_non_rRNA_reads.1.fastq \
    -2 ${results_rRNA}/${Sample}_non_rRNA_reads.2.fastq \
    -o ${results_megahit}/${Sample} \
    --min-contig-len 800 \
    
# genomad download-database /home/ubuntu/project/DB/genomad_db
genomad end-to-end \
    --cleanup \
    --splits 2 \
    --lenient-taxonomy \
    --full-ictv-lineage \
    --min-score 0.5 \
    --disable-find-proviruses \
    /home/ubuntu/project/test/results/megahit/IM22A007/final.contigs.fa \
    /home/ubuntu/project/test/results/genomad/IM22A007 \
    /home/ubuntu/project/DB/genomad_db
# 1输出目录需要存在
# 提取分类，方便以后分析Hantaviridae，output：两个表，一个是序列文件，另一个是分类文件，用id作为索引
# 用代码控制，传入分析路径。和输入一样

# hmmer
## 构建DB
# python /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/id_down.py 
# cd-hit -i /home/ubuntu/project/hanta_raw.faa -o /home/ubuntu/project/pep.out.fa.90 -c 0.9 -aS 0.8 -n 5 -g 1 -G 0 -d 0 -p 1 -M 0 -T 16
# mafft --localpair \
#         --maxiterate 1000 \
#         --thread 16 \
#         /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/pep.out.fa.90 > /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/hanta_aligned.faa

# hmmbuild /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/hanta_aligned.hmm /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/hanta_aligned.faa 
# hmmpress /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/hanta_aligned.hmm

## 比对分析
hmmsearch --tblout /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/hanta_hits.tbl \
            -E 1e-5 \
            --cpu 8 \
            /home/ubuntu/project/GitHub/Yu-Lab-Hantavirus/backup/hanta_aligned.hmm \
            /home/ubuntu/project/test/results/genomad/IM22A003/final.contigs_annotate/final.contigs_proteins.faa

hmmsearch \
    -E 1e-3 --domE 10 --cpu 16 --noali --acc --notextw \
    --domtblout /home/ubuntu/project/test/results/hmm/IM22A003.hmmsearch \
    /home/ubuntu/project/DB/hmm/hanta_aligned.hmm  \
    /home/ubuntu/project/test/results/megahit/IM22A003/final.contigs.fa

第六步：SeqKit 提取阳性 Contig 序列
bash
1. 从 HMMER 结果中提取蛋白 ID 并转换为 Contig ID
grep -v '^#' /home/ubuntu/project/test/results/hmm/IM22A003.hmmsearch | awk '{print $1}' | awk '{sub(/_[0-9]+$/, "", $1); print $1}' | sort -u > /home/ubuntu/project/test/results/hmm/IM22A003.id

2. 从 Megahit 组装的 Contig 中提取核酸 Fasta 序列
seqkit grep -f /home/ubuntu/project/test/results/hmm/IM22A003.id \
            /home/ubuntu/project/test/results/megahit/IM22A003/final.contigs.fa \
            -o /home/ubuntu/project/test/results/hmm/IM22A003.fna