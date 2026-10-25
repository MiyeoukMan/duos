# melonDS 코어 + DSCore를 정적 라이브러리로 묶는다(cmake 없이 clang만).
#   make                 → build/macos/libdscore.a, build/macos/dsrun(화면 없는 실행기)
#   make PLATFORM=ios    → build/ios/libdscore.a (앱이 링크한다 — Xcode 빌드 단계가 이걸 부른다)
#   make PLATFORM=iossim → build/iossim/libdscore.a (시뮬레이터)
#   make test            → 직접 만든 시험 ROM을 dsrun으로 돌려 본다

PLATFORM ?= macos
MELON := third_party/melonDS/src
ENET := third_party/enet
OUT := build/$(PLATFORM)

ifeq ($(PLATFORM),ios)
  SDK := iphoneos
  TARGET := -target arm64-apple-ios18.0
else ifeq ($(PLATFORM),iossim)
  SDK := iphonesimulator
  TARGET := -target arm64-apple-ios18.0-simulator
else
  SDK := macosx
  TARGET := -target arm64-apple-macos14.0
endif

SYSROOT := $(shell xcrun --sdk $(SDK) --show-sdk-path)
CC := $(shell xcrun --sdk $(SDK) -f clang)
CXX := $(shell xcrun --sdk $(SDK) -f clang++)
AR := $(shell xcrun --sdk $(SDK) -f libtool)

OPT ?= -O3
COMMON := $(TARGET) -isysroot $(SYSROOT) $(OPT) -DNDEBUG -fwrapv -MMD -MP \
          -I$(MELON) -I$(MELON)/teakra/include -I$(MELON)/teakra/src -I$(MELON)/net -I$(MELON)/net/libslirp/src -I$(ENET)/include -I$(OUT)/gen \
          -Wno-everything
CFLAGS := $(COMMON) -std=gnu11
CXXFLAGS := $(COMMON) -std=c++17 -fno-strict-aliasing

CORE_SRCS := ARCodeFile.cpp ARDatabaseDAT.cpp AREngine.cpp ARM.cpp ARMInterpreter.cpp ARMInterpreter_ALU.cpp \
  ARMInterpreter_Branch.cpp ARMInterpreter_LoadStore.cpp CP15.cpp CRC32.cpp DMA.cpp DMA_Timings.cpp DSi.cpp DSi_AES.cpp \
  DSi_Camera.cpp DSi_DSP.cpp DSi_I2C.cpp DSi_I2S.cpp DSi_NAND.cpp DSi_NDMA.cpp DSi_NWifi.cpp DSi_SD.cpp DSi_SPI_TSC.cpp \
  FATIO.cpp FATStorage.cpp GBACart.cpp GBACartMotionPak.cpp GPU.cpp GPU_Soft.cpp GPU2D.cpp GPU2D_Soft.cpp GPU3D.cpp \
  GPU3D_Soft.cpp GPU3D_Texcache.cpp Mic.cpp NDS.cpp NDSCart.cpp ROMList.cpp FreeBIOS.cpp RTC.cpp Savestate.cpp SPI.cpp \
  SPI_Firmware.cpp SPU.cpp Utils.cpp Wifi.cpp WifiAP.cpp DSP_HLE/UcodeBase.cpp DSP_HLE/AACUcode.cpp DSP_HLE/G711Ucode.cpp \
  DSP_HLE/GraphicsUcode.cpp NDSCart/CartCommon.cpp NDSCart/CartRetail.cpp NDSCart/CartRetailNAND.cpp \
  NDSCart/CartRetailIR.cpp NDSCart/CartRetailBT.cpp NDSCart/CartSD.cpp NDSCart/CartHomebrew.cpp NDSCart/CartR4.cpp \
  fatfs/ff.c fatfs/ffsystem.c fatfs/ffunicode.c sha1/sha1.c tiny-AES-c/aes.c xxhash/xxhash.c blip-buf/blip_buf.c \
  net/LAN.cpp net/MPInterface.cpp net/LocalMP.cpp net/Net.cpp net/Net_Slirp.cpp net/PacketDispatcher.cpp
TEAKRA_SRCS := ahbm.cpp apbp.cpp btdmp.cpp disassembler.cpp dma.cpp memory_interface.cpp mmio.cpp parser.cpp \
  processor.cpp teakra.cpp timer.cpp
# ENet(MIT) — melonDS의 LAN 통신(DS 근거리 무선을 UDP로)
ENET_SRCS := callbacks.c compress.c host.c list.c packet.c peer.c protocol.c unix.c
ENET_DEFS := -DHAS_GETADDRINFO -DHAS_GETNAMEINFO -DHAS_POLL -DHAS_FCNTL -DHAS_INET_PTON -DHAS_INET_NTOP -DHAS_MSGHDR_FLAGS -DHAS_SOCKLEN_T
# libslirp(BSD) — DS 인터넷(Nintendo WFC 대체 서버): 가상 공유기 뒤의 사용자 공간 NAT. glib는 melonDS에 든 작은 대용품
SLIRP := $(MELON)/net/libslirp
SLIRP_SRCS := arp_table.c bootp.c cksum.c dhcpv6.c dnssearch.c if.c ip6_icmp.c ip6_input.c ip6_output.c ip_icmp.c \
  ip_input.c ip_output.c mbuf.c misc.c ncsi.c ndp_table.c sbuf.c slirp.c socket.c state.c stream.c tcp_input.c \
  tcp_output.c tcp_subr.c tcp_timer.c tftp.c udp6.c udp.c util.c version.c vmstate.c
SLIRP_DEFS := -DLIBSLIRP_STATIC_BUILD -DBUILDING_LIBSLIRP '-DG_LOG_DOMAIN="Slirp"' -I$(SLIRP)/glib
OWN_SRCS := core/DSCore.cpp core/Platform_Apple.cpp core/DuoNet.cpp core/hires/DuoRenderer2D.cpp
# 3D 고해상도(Metal) — Objective-C++
OWN_MM_SRCS := core/hires/DuoRenderer.mm core/hires/Metal3D.mm core/hires/HiresShaders.mm

OBJS := $(patsubst %,$(OUT)/obj/melon/%.o,$(CORE_SRCS)) \
        $(patsubst %,$(OUT)/obj/teakra/%.o,$(TEAKRA_SRCS)) \
        $(patsubst %,$(OUT)/obj/enet/%.o,$(ENET_SRCS)) \
        $(patsubst %,$(OUT)/obj/slirp/%.o,$(SLIRP_SRCS)) $(OUT)/obj/slirp/glib.c.o \
        $(patsubst %,$(OUT)/obj/%.o,$(OWN_SRCS)) \
        $(patsubst %,$(OUT)/obj/%.o,$(OWN_MM_SRCS))

LIB := $(OUT)/libdscore.a
FRAMEWORKS := -framework Metal -framework Foundation
VERSION_H := $(OUT)/gen/version.h
SLIRP_VERSION_H := $(OUT)/gen/libslirp-version.h

ifneq ($(PLATFORM),macos)
all: $(LIB)
else
all: $(LIB) $(OUT)/dsrun $(OUT)/lantest $(OUT)/nettest
endif

$(VERSION_H): $(MELON)/version.h.in
	@mkdir -p $(dir $@)
	sed -e 's|$${melonDS_HOMEPAGE_URL}|https://melonds.kuribo64.net|' -e 's|$${melonDS_VERSION}|1.1|' \
	    -e 's|$${MELONDS_VERSION_SUFFIX}| (DuoDS)|' $< > $@

$(SLIRP_VERSION_H): $(SLIRP)/src/libslirp-version.h.in
	@mkdir -p $(dir $@)
	sed -e 's|@SLIRP_MAJOR_VERSION@|4|' -e 's|@SLIRP_MINOR_VERSION@|8|' -e 's|@SLIRP_MICRO_VERSION@|0|' \
	    -e 's|@SLIRP_VERSION_STRING@|"4.8.0"|' $< > $@

$(OUT)/obj/melon/%.cpp.o: $(MELON)/%.cpp | $(VERSION_H) $(SLIRP_VERSION_H)
	@mkdir -p $(dir $@)
	@echo "  CXX $<"
	@$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/obj/melon/%.c.o: $(MELON)/%.c | $(VERSION_H)
	@mkdir -p $(dir $@)
	@echo "  CC  $<"
	@$(CC) $(CFLAGS) -c $< -o $@

$(OUT)/obj/teakra/%.cpp.o: $(MELON)/teakra/src/%.cpp
	@mkdir -p $(dir $@)
	@echo "  CXX $<"
	@$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/obj/enet/%.c.o: $(ENET)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC  $<"
	@$(CC) $(CFLAGS) $(ENET_DEFS) -c $< -o $@

$(OUT)/obj/slirp/%.c.o: $(SLIRP)/src/%.c | $(SLIRP_VERSION_H)
	@mkdir -p $(dir $@)
	@echo "  CC  $<"
	@$(CC) $(CFLAGS) $(SLIRP_DEFS) -c $< -o $@

$(OUT)/obj/slirp/glib.c.o: $(SLIRP)/glib/glib.c
	@mkdir -p $(dir $@)
	@echo "  CC  $<"
	@$(CC) $(CFLAGS) $(SLIRP_DEFS) -c $< -o $@

$(OUT)/obj/core/%.cpp.o: core/%.cpp | $(VERSION_H) $(SLIRP_VERSION_H)
	@mkdir -p $(dir $@)
	@echo "  CXX $<"
	@$(CXX) $(CXXFLAGS) -Wall -Wno-unused-parameter -Wno-missing-braces -c $< -o $@

$(OUT)/obj/core/%.mm.o: core/%.mm | $(VERSION_H) $(SLIRP_VERSION_H)
	@mkdir -p $(dir $@)
	@echo "  OBJC++ $<"
	@$(CXX) $(CXXFLAGS) -x objective-c++ -fobjc-arc -Wall -Wno-unused-parameter -Wno-missing-braces -c $< -o $@

$(LIB): $(OBJS)
	@echo "  AR  $@"
	@$(AR) -static -no_warning_for_no_symbols -o $@ $^

$(OUT)/dsrun: tools/dsrun.cpp $(LIB)
	@echo "  LD  $@"
	@$(CXX) $(CXXFLAGS) -Icore tools/dsrun.cpp $(LIB) -lz -lresolv $(FRAMEWORKS) -o $@

$(OUT)/lantest: tools/lantest.cpp $(LIB)
	@echo "  LD  $@"
	@$(CXX) $(CXXFLAGS) -Icore tools/lantest.cpp $(LIB) -lz -lresolv $(FRAMEWORKS) -o $@

$(OUT)/nettest: tools/nettest.cpp $(LIB)
	@echo "  LD  $@"
	@$(CXX) $(CXXFLAGS) -Icore tools/nettest.cpp $(LIB) -lz -lresolv $(FRAMEWORKS) -o $@

test: all
	python3 tools/mkrom.py build/test.nds
	python3 tools/mkrom.py --scene3d build/scene3d.nds
	python3 tools/test.py

clean:
	rm -rf build

.PHONY: all test clean

-include $(OBJS:.o=.d)
