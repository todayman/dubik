dubik: source/dubik.d
	../dlang_rxrpc/dmd/src/dmd -color=on \
		-I../dlang_rxrpc/phobos \
		-I../dlang_rxrpc/druntime/import \
		-defaultlib= \
		../dlang_rxrpc/phobos/generated/linux/release/64/libphobos2.a \
		../dlang_rxrpc/druntime/lib/libdruntime-linux64.a \
		source/dubik.d \
		-ofdubik
