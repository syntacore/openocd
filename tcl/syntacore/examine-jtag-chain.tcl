# SPDX-License-Identifier: GPL-2.0-or-later

namespace eval syntacore::jtag {
	## Chain contents, in TDO->TDI order: one element per device found by
	## scan_idcodes: an empty dict for a BYPASS device, or a dict with a
	## single entry {"idcode" <number>} for a device that responded with an
	## IDCODE.
	variable chain
	## Number of bits scanned per plain-scan when reading the chain.
	## Must be a multiple of 8.
	variable scan_chunk 256
	## Maximum number of consecutive zero (BYPASS) bits tolerated at the end
	## of the scan. 0 disables the limit.
	variable trailing_zero_limit 65

	## Prints the chain to the console in human-readable form: one line per
	## device, delimited by "0. TDO" and "N. TDI".
	proc output_human {} {
		variable chain
		echo "JTAG chain:"
		echo "0. TDO"
		set idx 1
		foreach entry $chain {
			if {[dict exists $entry idcode]} {
				echo "$idx. IDCODE=[dict get $entry idcode]"
			} else {
				echo "$idx. BYPASS"
			}
			incr idx
		}
		echo "$idx. TDI"
	}

	## Writes the chain to "channel" as a JSON array of objects; each object
	## has an "idcode" member, omitted for BYPASS devices.
	## @param[in] "channel" output channel (e.g. stdout)
	proc output_json {channel} {
		variable chain
		puts $channel [json::encode $chain {list obj idcode num}]
	}

	## Scans the JTAG chain in TDO->TDI order and stores the result in
	## "chain". Performs transport initialization first. Errors carry an
	## -errorcode of the form {SYNTACORE JTAG <CLASS> <CODE>}.
	## @exception "CONNECTION" JTAG connection problems.
	## @exception "CONFIG" configuration problems.
	proc scan_idcodes {} {
		variable chain
		variable scan_chunk
		variable trailing_zero_limit

		internal::startup $scan_chunk
		set chain [list]
		set view [internal::new $scan_chunk]
		set trailing_bypasses 0

		while {1} {
			lassign [internal::chainview::next $view] item view
			lappend chain $item
			if {$trailing_zero_limit == 0} {
				continue
			}
			if {$item ne {}} {
				set trailing_bypasses 0
				continue
			}
			incr trailing_bypasses
			if {$trailing_bypasses >= $trailing_zero_limit} {
				internal::raise [list CONNECTION TRAILING_ZEROES] "Seems like a JTAG connection issue: more than \
					$trailing_zero_limit trailing zero bits"
			}
		}
	}
}

namespace eval syntacore::jtag::internal {
	variable tdi_pattern ff000000
	variable error_prefix "SYNTACORE JTAG"
	proc startup {scan_chunk} {
		if {$scan_chunk % 8 != 0} {
			raise [list CONFIG SCAN_CHUNK_INCOMMENSURABLE] "scan_chunk ($scan_chunk) is not a multiple of 8"
		}
		proc ::jtag_init {} {}
		transport select jtag
		if {[catch init msg]} {
			raise [list CONFIG INIT_FAIL] "Failed to initialize: $msg"
		}
	}
	proc raise {code msg} {
		variable error_prefix
		return -code error -level 0 -errorcode [list {*}$error_prefix {*}$code] $msg
	}
	proc new {scan_chunk} {
		return [chainview::new [inview::new [outgen::new] $scan_chunk]]
	}
}

namespace eval syntacore::jtag::internal::outgen {
	namespace export make
	proc new {} {
		return [dict create offset_nibbles 0]
	}
	proc make {state n_bits} {
		if {$n_bits % 8 != 0} {
			error "outgen::make: $n_bits is not a multiple of 8"
		}
		dict with state {
			set hex_len [expr {$offset_nibbles + $n_bits / 4}]
			set buf [string repeat $::syntacore::jtag::internal::tdi_pattern \
				[expr {($hex_len + 7) / 8}]]
			set hex [string range $buf $offset_nibbles [expr {$hex_len - 1}]]
			set offset_nibbles [expr {$hex_len % 8}]
		}
		return [list $hex $state]
	}
}

namespace eval syntacore::jtag::internal::inview {
	namespace export get_bit get_word advance
	namespace import ::syntacore::jtag::internal::outgen::make
	proc new {gen_state scan_chunk} {
		jtag pathmove RESET IDLE
		return [dict create gen $gen_state hex "" scanned 0 cursor 0 \
			chunk $scan_chunk]
	}
	proc scan_more {state} {
		dict with state {
			lassign [make $gen $chunk] tdi gen
			append hex [jtag execute plain-scan -dr $chunk $tdi -endstate DRPAUSE]
			incr scanned $chunk
		}
		return $state
	}
	proc ensure {state n_bits} {
		while {[dict get $state scanned] - [dict get $state cursor] < $n_bits} {
			set state [scan_more $state]
		}
		return $state
	}
	proc get_bit {state} {
		set state [ensure $state 1]
		dict with state {
			set byte_i [expr {$cursor / 8}]
			set str_i [expr {$byte_i * 2}]
			set bit_i [expr {$cursor % 8}]
			set c 0x[string range $hex $str_i $str_i+1]
			set bit [expr {($c >> $bit_i) & 1}]
		}
		return [list $bit $state]
	}
	proc get_word {state} {
		set state [ensure $state 32]
		dict with state {
			set str_i [expr {$cursor / 8 * 2}]
			set bit_i [expr {$cursor % 8}]
			set word_hex {}
			for {set i 0} {$i < 5} {incr i} {
				set word_hex "[string range $hex [expr {$str_i + $i * 2}] \
					[expr {$str_i + $i * 2 + 1}]]$word_hex"
			}
			set lo [format %u 0x[string range $word_hex end-1 end]]
			set hi [format %u 0x[string range $word_hex 0 end-2]]
			# Combine the lowest byte and the remaining bits against the
			# bit offset, pre-masking the high part so no intermediate
			# value exceeds 32 bits on 32-bit-integer builds.
			set word [expr {(($hi & (0xffffffff >> (8 - $bit_i))) << (8 - $bit_i)) | ($lo >> $bit_i)}]
		}
		return [list $word $state]
	}
	proc advance {state n_bits} {
		dict with state {
			incr cursor $n_bits
			if {$cursor > $scanned} {
				error "inview::advance beyond scanned data"
			}
		}
		return $state
	}
}

namespace eval syntacore::jtag::internal::chainview {
	namespace import ::syntacore::jtag::internal::inview::get_bit \
		::syntacore::jtag::internal::inview::get_word \
		::syntacore::jtag::internal::inview::advance \
		::syntacore::jtag::internal::raise
	proc new {inview_state} {
		return [dict create inview $inview_state]
	}
	proc next {state} {
		dict with state {
			lassign [get_bit $inview] bit inview
			if {$bit == 0} {
				set inview [advance $inview 1]
				set item [dict create]
			} else {
				lassign [get_word $inview] word inview
				if {$word == 0xff} {
					return -code break
				}
				if {$word == 0xffffffff} {
					raise [list CONNECTION INVALID_IDCODE] \
						"Seems like a JTAG connection issue: all-ones IDCODE detected"
				}
				set inview [advance $inview 32]
				set item [dict create idcode $word]
			}
		}
		return [list $item $state]
	}
}
