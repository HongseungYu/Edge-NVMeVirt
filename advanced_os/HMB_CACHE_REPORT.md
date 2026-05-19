# NVMeVirt HMB L2P Cache 시뮬레이터 구현 보고서

> **Branch:** `hmb`  
> **날짜:** 2026-05-19  
> **수정 파일:** `Kbuild`, `main.c`, `conv_ftl.h`, `conv_ftl.c`, `ssd_config.h`, `hmb_cache.h`(신규), `hmb_cache.c`(신규)  
> **추가 파일:** `advanced_os/bench_hmb_latency.py`, `advanced_os/verify_nvmev_arm64.sh`

---

## 1. 배경 및 목표

DRAM이 없는 NVMe SSD 컨트롤러는 L2P(Logical-to-Physical) 변환 테이블 전체를 온-칩 SRAM에 올릴 수 없다. 실제 하드웨어는 다음과 같은 3-tier 구조로 이를 처리한다.

| Tier | 매체 | 접근 지연 (대표값) |
|------|------|--------------------|
| 1 | On-chip SRAM | ~100 ns |
| 2 | Host Memory Buffer (HMB, PCIe) | ~1,000 ns |
| 3 | NAND Flash (mapping segment fetch) | ~30,000 ns |

NVMeVirt는 기존에 L2P 조회 지연을 모델링하지 않았다. 본 작업의 목표는 위 3-tier 캐시를 커널 모듈 내에서 시뮬레이션하여, 캐시 크기·지연·교체 정책이 전체 I/O 성능에 미치는 영향을 실험할 수 있게 하는 것이다.

---

## 2. 신규 파일

### 2.1 `hmb_cache.h` — 자료구조 및 공개 API 정의

```
struct hmb_cache_entry   // 캐시 항목: (lpn, ppa) + LRU 링크 + 해시 링크
struct hmb_cache_tier    // 단일 tier (SRAM 또는 HMB): pool 배열, LRU 리스트, 해시 테이블
struct nvmev_hmb_cache   // 전체 캐시 객체: SRAM tier + HMB tier + 통계 + 스핀락
enum   hmb_repl_policy   // HMB_REPL_LRU(0) | HMB_REPL_RANDOM(1)
```

공개 함수:

```c
int      hmb_cache_init   (struct nvmev_hmb_cache *cache, uint32_t sram_entries,
                           uint32_t hmb_entries, uint64_t lat_sram_ns,
                           uint64_t lat_hmb_ns, uint64_t lat_nand_ns,
                           enum hmb_repl_policy policy);
void     hmb_cache_fini   (struct nvmev_hmb_cache *cache);
uint64_t hmb_cache_lookup (struct nvmev_hmb_cache *cache, uint64_t lpn, const struct ppa *ppa);
void     hmb_cache_update (struct nvmev_hmb_cache *cache, uint64_t lpn, const struct ppa *ppa);
```

### 2.2 `hmb_cache.c` — 구현

#### 2.2.1 내부 tier 헬퍼

- **`tier_init`** : `vmalloc`으로 `pool[]` (항목 배열)과 `htable[]` (해시 버킷 배열) 할당. 버킷 수는 capacity의 다음 2의 거듭제곱으로 설정하여 해시 충돌 최소화.
- **`tier_fini`** : `vfree` 후 필드 초기화.
- **`tier_lookup`** : `hash_64(lpn, htable_bits)` → 버킷 순회 → O(1) 탐색.
- **`tier_promote`** : `list_move`로 LRU 리스트 head로 이동.
- **`tier_insert`** : 빈 슬롯이 있으면 warmup 경로(`next_free++`), 꽉 찼으면 교체 정책에 따라 희생자 선택.
  - `LRU`: `list_last_entry`로 tail 항목 교체.
  - `RANDOM`: `get_random_u32() % capacity`로 균등 랜덤 교체.

#### 2.2.2 `hmb_cache_lookup` (읽기 경로)

```
1. SRAM 탐색 → 히트: promote, lat_sram_ns 반환
2. HMB 탐색  → 히트: lat_hmb_ns 반환 + SRAM으로 승격(tier_insert)
3. NAND 미스 : lat_nand_ns 반환 + HMB에 신규 삽입
```

전체 구간은 `spin_lock_irqsave` / `spin_unlock_irqrestore`로 보호.

#### 2.2.3 `hmb_cache_update` (쓰기 경로)

쓰기 이후 PPA가 변경되므로 캐시도 갱신해야 한다.

```
1. SRAM에 있으면 → in-place PPA 업데이트 + promote
   HMB 섀도 항목도 있으면 동일 갱신
2. SRAM에 없고 HMB에 있으면 → in-place 업데이트 + SRAM으로 승격
3. 둘 다 없으면(퇴출된 상태) → HMB에 신규 삽입
```

`tier_insert`를 맹목적으로 호출하지 않고 lookup-then-update 패턴을 사용하여 동일 LPN 중복 항목 생성 버그를 방지한다.

---

## 3. 기존 파일 수정

### 3.1 `conv_ftl.h`

- `struct convparams`에서 `double op_area_pcent` 필드 제거 (→ `ssd_config.h`의 정수 상수로 대체).
- `struct conv_ftl`에 캐시 포인터 추가:
  ```c
  struct nvmev_hmb_cache *hmb_cache;  // nr_parts 인스턴스가 공유
  ```
- `#include "hmb_cache.h"` 추가.

### 3.2 `conv_ftl.c`

#### (a) `get_maptbl_ent_cached` 래퍼 추가

```c
static inline struct ppa get_maptbl_ent_cached(
        struct conv_ftl *conv_ftl,
        uint64_t local_lpn,   // maptbl[] 인덱스
        uint64_t global_lpn,  // 캐시 키 (파티션 간 유일)
        uint64_t *lat_ns)
```

`maptbl[]`의 PPA는 항상 `local_lpn`으로 정확하게 읽고, 캐시 키로는 파티션을 곱하지 않은 `global_lpn`(= 호스트 LPN)을 사용한다. 파티션별 L2P 분할 때문에 `local_lpn`만 사용하면 서로 다른 파티션의 LPN이 캐시 키가 충돌하는 버그가 발생한다.

#### (b) `conv_init_namespace` — 캐시 초기화

```c
if (sram_size_kb > 0 || hmb_size_mb > 0) {
    cache = kmalloc(sizeof(*cache), GFP_KERNEL);
    hmb_cache_init(cache, sram_entries, hmb_entries,
                   lat_sram_ns, lat_hmb_ns, lat_nand_ns,
                   (enum hmb_repl_policy)repl_policy);
    for (i = 0; i < nr_parts; i++)
        conv_ftls[i].hmb_cache = cache;  // 파티션이 동일 객체 공유
}
```

`L2P_ENTRY_BYTES = 16` (lpn 8 B + ppa 8 B)로 MiB/KiB를 항목 수로 변환.

#### (c) `conv_remove_namespace` — 캐시 해제

```c
hmb_cache_fini(conv_ftls[0].hmb_cache);  // dmesg에 통계 출력
kfree(conv_ftls[0].hmb_cache);
```

#### (d) 읽기 경로 (`conv_read`) — L2P 지연 반영

페이지 그룹 병합 루프를 수정하여 L2P 조회 지연이 NAND read 시작 시각에 반영되도록 했다.

```c
uint64_t l2p_lat = 0;   // 누산 지연
uint64_t l2p_now;       // 파티션 기준 현재 타임스탬프

// 파티션마다 l2p_now 리셋 (파티션은 병렬 처리)
for (i = 0; i < nr_parts; ...) {
    l2p_now = srd.stime;
    for (lpn = start_lpn; lpn <= end_lpn; lpn += nr_parts) {
        prev_lat = l2p_lat;
        l2p_for_prev = l2p_now;                          // 이전 그룹 기준 시각 스냅샷
        cur_ppa = get_maptbl_ent_cached(..., lpn, &l2p_lat);
        l2p_now += l2p_lat - prev_lat;                   // 이번 조회 지연만큼 전진
        if (page boundary) {
            srd.stime = l2p_for_prev;                    // 이전 그룹은 스냅샷 기준
            ssd_advance_nand(...);
        }
    }
    srd.stime = l2p_now;                                 // 마지막 그룹은 최신 기준
    ssd_advance_nand(...);
}
```

각 파티션은 독립적으로 타임라인을 관리하므로 파티션 간 L2P 직렬화가 발생하지 않는다.

#### (e) 쓰기 경로 (`conv_write`)

- `get_maptbl_ent` → `get_maptbl_ent_cached`로 교체 (이전 PPA 조회 시 캐시 통계 반영).
- `set_maptbl_ent` 후 `hmb_cache_update` 호출하여 새 PPA를 캐시에 반영.

### 3.3 `main.c` — 모듈 파라미터 추가

```c
unsigned int hmb_size_mb  = 16;   // HMB tier 크기 (MiB)
unsigned int sram_size_kb = 256;  // SRAM tier 크기 (KiB)
unsigned int lat_sram_ns  = 100;  // SRAM 히트 지연 (ns)
unsigned int lat_hmb_ns   = 1000; // HMB 히트 지연 (ns)
unsigned int lat_nand_ns  = 30000;// NAND 미스 지연 (ns)
unsigned int repl_policy  = 0;    // 교체 정책: 0=LRU, 1=RANDOM
```

모두 `module_param` 및 `MODULE_PARM_DESC`로 등록되어 있어 `insmod` 시 인라인으로 전달하거나 `/sys/module/nvmev/parameters/`를 통해 런타임에 읽을 수 있다.

### 3.4 `ssd_config.h`

```c
// before
#define OP_AREA_PERCENT (0.07)   // double

// after
#define OP_AREA_PERCENT (7)      // int (percent)
```

커널 코드에서 `double`을 사용하면 soft-float 링크 문제가 발생할 수 있다. `conv_ftl.c`의 계산도 `100 + OP_AREA_PERCENT`로 단순화.

### 3.5 `Kbuild`

```makefile
# before
nvmev-$(CONFIG_NVMEVIRT_SSD) += ssd.o conv_ftl.o pqueue/pqueue.o channel_model.o

# after
nvmev-$(CONFIG_NVMEVIRT_SSD) += ssd.o conv_ftl.o hmb_cache.o pqueue/pqueue.o channel_model.o
```

빌드 대상도 `CONFIG_NVMEVIRT_NVM → CONFIG_NVMEVIRT_SSD`로 전환.

### 3.6 `advanced_os/verify_nvmev_arm64.sh` — `show_hmb_stats` 추가

`rmmod` 후 `dmesg`에서 `"HMB cache stats:"` 라인을 파싱하여 다음 형식으로 출력하는 함수 추가:

```
============================================================
 HMB Cache Statistics
============================================================
  SRAM hits:              12345  (62%)
  HMB hits:               4321  (21%)
  NAND fetches:           3334  (17%)
  --------------------------------------------------
  Total L2P lookups:     20000
  Cache hit rate:           83%
  NAND miss rate:           17%
============================================================
```

`phase2_test` 마지막 `print_summary` 직전에 호출된다.

---

## 4. 주요 버그 수정

### Bug 1 (Critical): 캐시 키 충돌 (`local_lpn` → `global_lpn`)

**문제:** 파티션이 4개(`nr_parts=4`)일 때, 파티션 0~3의 LPN 0은 모두 `local_lpn=0`으로 변환된다. 공유 캐시가 파티션별로 같은 키를 갖게 되어 실제 working set의 1/4만 캐시에 반영 → 캐시 효율이 4배 과대평가됨.

**수정:** `get_maptbl_ent_cached`에 `global_lpn` 파라미터를 별도로 추가하고, 호출부에서 나눗셈 전의 원래 `lpn`을 넘기도록 변경.

### Bug 2: 쓰기 후 캐시에 stale PPA 잔존

**문제:** `get_maptbl_ent_cached`가 `set_maptbl_ent` 이전에 호출되어 캐시에 기존(또는 미매핑) PPA가 들어간다. 이후 읽기에서 캐시 히트 시 잘못된 PPA를 반환할 수 있다.

**수정:** `set_maptbl_ent` + `set_rmap_ent` 완료 후 `hmb_cache_update(conv_ftl->hmb_cache, lpn, &ppa)` 호출.

### Bug 3: `tier_insert` 중복 항목 생성

**문제:** `tier_insert`는 LPN이 이미 캐시에 있는지 확인하지 않으므로, 같은 LPN에 대해 두 번 호출되면 해시 테이블에 두 개의 항목이 생긴다.

**수정:** `hmb_cache_update`에서 기존 항목을 lookup 후 in-place 업데이트하고, 퇴출된 경우에만 `tier_insert`를 fallback으로 사용.

---

## 5. 벤치마크 스크립트 (`advanced_os/bench_hmb_latency.py`)

루트 권한으로 실행하는 파라미터 스윕 자동화 스크립트.

### 동작 흐름

1. `/boot/nvmev-arm64.env`에서 `memmap` 설정 로드 (`verify_nvmev_arm64.sh --phase=1`이 생성).
2. 각 파라미터 값에 대해 `insmod nvmev.ko <params>` → `dd` 또는 `fio`로 측정 → `rmmod` → `dmesg`에서 히트율 파싱.
3. 결과를 matplotlib으로 2행 그래프로 시각화 (위: 처리량, 아래: 캐시 히트율).

### 스윕 대상 파라미터 및 기본값

| 파라미터 | 기본값 | 스윕 범위 |
|----------|--------|-----------|
| `sram_size_kb` | 512 KiB | 0, 64, 128, 256, 512, 1024 |
| `hmb_size_mb`  | 4 MiB  | 0, 1, 2, 3, 4 |
| `lat_sram_ns`  | 100 ns | 50–5000 |
| `lat_hmb_ns`   | 3000 ns | 500–50000 |
| `lat_nand_ns`  | 40000 ns | 10000–200000 |

### 사용 예

```bash
# 전체 파라미터 dd 스윕 (기본)
sudo python3 advanced_os/bench_hmb_latency.py

# 특정 파라미터만 fio randread 스윕
sudo python3 advanced_os/bench_hmb_latency.py \
    --params sram_size_kb hmb_size_mb \
    --workload fio --fio-rw randread

# 결과 CSV 저장
sudo python3 advanced_os/bench_hmb_latency.py --csv results.csv
```

출력 그래프: `advanced_os/hmb_latency_sweep.png`

---

## 6. 아키텍처 요약

```
                    conv_read / conv_write
                           │
                           ▼
              get_maptbl_ent_cached(local_lpn, global_lpn, &lat_ns)
                    │              │
                    │ (PPA)        │ (latency)
                    ▼              ▼
              maptbl[local_lpn]   hmb_cache_lookup(global_lpn, ppa)
                                        │
                    ┌───────────────────┼──────────────────────┐
                    ▼                   ▼                      ▼
              [SRAM tier]         [HMB tier]           [NAND miss]
              (on-chip, fast)   (PCIe, medium)      (flash, slow)
              lat_sram_ns       lat_hmb_ns           lat_nand_ns
              ~100 ns           ~1,000 ns            ~30,000 ns
```

- **maptbl[]** : 항상 정확한 PPA의 source of truth. 캐시는 PPA를 저장하지만 반환값은 항상 maptbl에서 읽는다.
- **캐시** : 지연 모델링 전용. 읽기에서는 히트율/지연 통계만 누산; 쓰기에서는 PPA를 최신으로 유지.
- **공유 구조** : `nr_parts` 파티션이 하나의 `nvmev_hmb_cache` 객체를 포인터로 공유하며, `spinlock`으로 동시 접근을 보호한다.

---

## 7. 모듈 로드/언로드 예시

```bash
# 커스텀 파라미터로 로드
sudo insmod nvmev.ko \
    memmap_start=0x240000000 memmap_size=0x40000000 cpus=2,3 \
    hmb_size_mb=8 sram_size_kb=512 \
    lat_sram_ns=100 lat_hmb_ns=1000 lat_nand_ns=30000 \
    repl_policy=0

# 언로드 (dmesg에 캐시 통계 출력됨)
sudo rmmod nvmev
dmesg | grep "HMB cache"
```

예상 dmesg 출력:

```
nvmev: HMB cache init: SRAM 32768 entries (100 ns), HMB 524288 entries (1000 ns), NAND miss 30000 ns, policy=LRU
nvmev: HMB cache stats: SRAM hits=XXXXXX  HMB hits=XXXXXX  NAND fetches=XXXXXX
```
