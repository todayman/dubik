dubik: Makefile source/dubik.d source/message_headers.d source/vibe/core/drivers/rx.d
	../dlang_rxrpc/dmd/src/dmd -color=on \
		-I../dlang_rxrpc/phobos \
		-I../dlang_rxrpc/druntime/import \
		-I../../.dub/packages/vibe-d-0.7.21/source/ \
		-I../../.dub/packages/libevent-2.0.1_2.0.16 \
		-I../../.dub/packages/openssl-1.0.0_1.0.0e \
		-defaultlib= \
		../dlang_rxrpc/phobos/generated/linux/release/64/libphobos2.a \
		../dlang_rxrpc/druntime/lib/libdruntime-linux64.a \
		source/dubik.d \
		source/message_headers.d \
		source/vibe/core/drivers/rx.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/appmain.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/core/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/core/drivers/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/crypto/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/data/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/http/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/inet/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/internal/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/internal/meta/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/stream/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/textfilter/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/templ/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/utils/*.d \
		~/.dub/packages/vibe-d-0.7.21/source/vibe/web/*.d \
		-L-levent \
		-L-lssl \
		-L-lcrypto \
		-version=VibeCustomMain \
		-version=VibeLibeventDriver \
		-ofdubik
