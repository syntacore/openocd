# SPDX-License-Identifier: GPL-2.0-or-later

# A collection of scripts to manipulate RISC-V cores using low-level JTAG
# commands
#
# Call ocdjtag_riscv_update_taps_info before using the library to discover
# TAPs and disable polling. Keep polling off during low-level access.
# Refresh explicitly after topology changes or device reconfiguration.
#
# Copyright (c) 2023-2025, Syntacore LLC

set __JTAG_TAPS_INFO [dict create]

namespace eval __SC_JTAGLIB_INTERNAL {
    # JTAG instructions and DTM control fields. VALUE_MASK is unshifted.
    variable IR_DTMCS 0x10
    variable IR_DMI 0x11
    variable DTMCS_DMIRESET 0x10000
    variable DTMCS_IDLE_SHIFT 12
    variable DTMCS_IDLE_VALUE_MASK 0x7
    variable DTMCS_DMISTAT_SHIFT 10
    variable DTMCS_DMISTAT_VALUE_MASK 0x3
    variable DTMCS_ABITS_SHIFT 4
    variable DTMCS_ABITS_VALUE_MASK 0x3f
    variable DTMCS_VERSION_MASK 0xf

    # DMI scan layout: op/status, 32-bit data, then the DTM-sized address.
    variable DMI_OP_MASK 0x3
    variable DMI_DATA_SHIFT 2
    variable DMI_DATA_MASK 0xffffffff
    variable DMI_ADDRESS_SHIFT 34
    variable DMI_NOP 0
    variable DMI_READ 1
    variable DMI_WRITE 2
    variable DMI_SUCCESS 0
    variable DMI_FAILED 2
    variable DMI_BUSY 3

    # DMI address of the system bus control and status register.
    variable DM_SBCS       0x38

    # SBCS field positions and unshifted masks.
    variable SBCS_SBVERSION_SHIFT 29
    variable SBCS_SBVERSION_VALUE_MASK 0x7
    variable SBCS_SBACCESS_SHIFT 17
    variable SBCS_SBACCESS_VALUE_MASK 0x7
    variable SBCS_SBERROR_SHIFT 12
    variable SBCS_SBERROR_VALUE_MASK 0x7
    variable SBCS_SBASIZE_SHIFT 5
    variable SBCS_SBASIZE_VALUE_MASK 0x7f

    proc sc_jtaglib_get_tap_info { tap_num } {
        set taps_info [ocdjtag_riscv_get_taps_info]
        if {![dict exists $taps_info $tap_num]} {
            error "TAP $tap_num is not present in cached TAP information"
        }
        return [dict get $taps_info $tap_num]
    }

    proc sc_jtaglib_verbose { message { level 2 } } {
        if {[debug_level] >= $level} {
            echo $message
        }
    }

    proc sc_jtaglib_get_op_latency {} {
        set op_latency 1000
        # return time in milliseconds
        return 1000
    }

    proc sc_jtaglib_increase_dmi_busy_delay { current_delay } {
        return [expr {($current_delay / 10) + 1 + $current_delay}]
    }

    proc sc_jtaglib_exec_runtest { current_delay } {
        runtest $current_delay
    }

    proc sc_jtaglib_clear_sticky { tap_name } {
        variable IR_DTMCS
        variable DTMCS_DMIRESET
        irscan $tap_name $IR_DTMCS

        drscan $tap_name 32 $DTMCS_DMIRESET
    }

    proc sc_jtaglib_dmi_scan_timeout { tap_name dmi_size hex_dmi_val dtmcs_idle } {
        variable IR_DMI
        variable DMI_OP_MASK
        variable DMI_NOP
        variable DMI_SUCCESS
        variable DMI_BUSY
        variable DMI_FAILED

        set dmi_busy_delay $dtmcs_idle
        set timeout_ms [sc_jtaglib_get_op_latency]
        set start_time [clock milliseconds]
        set current_time $start_time
        set scan_value $hex_dmi_val
        set phase submission
        if {($hex_dmi_val & $DMI_OP_MASK) == $DMI_NOP} {
            # A caller-supplied NOP only waits for the transport to become idle.
            set phase completion
        }

        irscan $tap_name $IR_DMI
        while {1} {
            if {($current_time - $start_time) >= $timeout_ms} {
                error "Timed out during $phase"
            }
            # Wait before Capture-DR, also after clearing sticky BUSY.
            sc_jtaglib_exec_runtest $dmi_busy_delay
            set res [format 0x%s [drscan $tap_name $dmi_size $scan_value]]
            set status [expr {$res & $DMI_OP_MASK}]
            switch -- $status \
                $DMI_SUCCESS {
                    if {$phase eq "completion"} {
                        break
                    }
                    # The returned status belongs to the previous request.
                    # Our request has just been accepted. Send NOPs to collect
                    # its result without submitting it again.
                    set phase completion
                    set scan_value $DMI_NOP
                } \
                $DMI_BUSY {
                    # The DTM ignored this scan's request. Clear BUSY without
                    # cancelling outstanding work. Retry an ignored submission;
                    # after acceptance, continue polling with NOPs.
                    sc_jtaglib_clear_sticky $tap_name
                    set dmi_busy_delay \
                        [sc_jtaglib_increase_dmi_busy_delay $dmi_busy_delay]
                    irscan $tap_name $IR_DMI
                } \
                $DMI_FAILED {
                    sc_jtaglib_clear_sticky $tap_name
                    error "DMI operation failed (status $status) during $phase"
                } \
                default {
                    error "Reserved DMI status $status during $phase"
                }
            set current_time [clock milliseconds]
        }
        return $res
    }

    proc sc_jtaglib_get_tap_data_from_str { str } {
        if {[regexp {^\s([0-9]+)\s([0-9a-zA-Z]+\.[0-9a-zA-z]+)} $str m number name]} {
            return [list number $number name $name]
        } else {
            error "\[\"$str\"\]: fail to parse line (with tap info) of scan_chain output"
        }
    }

    proc sc_jtaglib_parse_header_first { str } {
        if {[regexp {^[ ]+TapName[ ]+Enabled[ ]+IdCode[ ]+Expected[ ]+IrLen[ ]+IrCap[ ]+IrMask} $str m]} {
            return 1
        } else {
            error "\[\"$str\"\]: fail to parse line (header first line) of scan_chain output"
        }
    }

    proc sc_jtaglib_parse_header_second { str } {
        if {[regexp {^-- ------------------- -------- ---------- ---------- ----- ----- ------} $str m]} {
            return 1
        } else {
            error "\[\"$str\"\]: fail to parse line (header second line) of scan_chain output"
        }
    }

    proc sc_jtaglib_parse_scan_chain { report } {
        set tap_count 0
        set tap_list [dict create]

        set rlines [split $report "\n"]

        #For example:
        #   TapName             Enabled  IdCode     Expected   IrLen IrCap IrMask
        #-- ------------------- -------- ---------- ---------- ----- ----- ------
        # 0 riscv.tap1             Y     0xdeadbeef 0x00000000     5 0x01  0x0
        # here we try to parse TapName and corresponding number

        set first_line [lindex $rlines 0]
        if {[sc_jtaglib_parse_header_first $first_line]} {
            set rlines [lreplace $rlines 0 0]
        }

        #index is zero again here because first line was removed in previous if statements
        set second_line [lindex $rlines 0]
        if {[sc_jtaglib_parse_header_second $second_line]} {
            set rlines [lreplace $rlines 0 0]
        }

        set last_line [lindex $rlines end]
        if {$last_line eq ""} {
            set rlines [lreplace $rlines end end]
        }

        foreach line $rlines {
          set parse_res [sc_jtaglib_get_tap_data_from_str $line]

          set cur_number [dict get $parse_res number]
          set cur_name [dict get $parse_res name]

          dict set tap_list $cur_number $cur_name
          set tap_count [expr {$tap_count + 1}]
        }

        if {$tap_count == 0} {
            error "No TAP's found"
        }

        return [list tap_count $tap_count tap_list $tap_list]
    }

    proc sc_jtaglib_get_dtmcs_by_name { tap_name } {
        variable IR_DTMCS
        variable DTMCS_DMIRESET
        variable DTMCS_IDLE_SHIFT
        variable DTMCS_IDLE_VALUE_MASK
        variable DTMCS_DMISTAT_SHIFT
        variable DTMCS_DMISTAT_VALUE_MASK
        variable DTMCS_ABITS_SHIFT
        variable DTMCS_ABITS_VALUE_MASK
        variable DTMCS_VERSION_MASK

        irscan $tap_name $IR_DTMCS
        set dtmcs_bitval [format 0x%s [drscan $tap_name 32 0x0]]

        return [dict create \
            dmireset [expr {($dtmcs_bitval & $DTMCS_DMIRESET) != 0}] \
            idle     [expr {
                ($dtmcs_bitval >> $DTMCS_IDLE_SHIFT) &
                $DTMCS_IDLE_VALUE_MASK
            }] \
            dmistat  [expr {
                ($dtmcs_bitval >> $DTMCS_DMISTAT_SHIFT) &
                $DTMCS_DMISTAT_VALUE_MASK
            }] \
            abits    [expr {
                ($dtmcs_bitval >> $DTMCS_ABITS_SHIFT) &
                $DTMCS_ABITS_VALUE_MASK
            }] \
            version  [expr {$dtmcs_bitval & $DTMCS_VERSION_MASK}] \
            is_zero  [expr {$dtmcs_bitval == 0}] \
        ]
        # is_zero is not a field of register, it's created just for using in examine_hart function
    }

    #list of copies of openocd C functions
    proc sc_jtaglib_set_field { reg mask val} {
        return [expr {((($reg) & ~($mask)) | ((($val) * (($mask) & ~(($mask) << 1))) & ($mask)))}]
    }

    proc sc_jtaglib_get_field { reg mask } {
        return [expr {((($reg) & ($mask)) / (($mask) & ~(($mask) << 1)))}]
    }

    proc sc_jtaglib_access_register_command { tap_num number size flags } {
        set command [sc_jtaglib_set_field 0 0xff000000 0]

        if {$size == 32} {
            set command [sc_jtaglib_set_field $command 0x700000 2]
        } elseif {$size == 64} {
            set command [sc_jtaglib_set_field $command 0x700000 3]
        } else {
            error "access_register_command->\[$tap_num\] $size bit register $number not supported"
        }

        if {$number <= 31} {
            set command [sc_jtaglib_set_field $command 0xffff [expr {0x1000 + $number}]]
        } elseif {$number >= 33 && $number <= 64} {
            set command [sc_jtaglib_set_field $command 0xffff [expr {0x1020 + $number - 33}]]
        } elseif {$number >= 65 && $number <= 4160} {
            set command [sc_jtaglib_set_field $command 0xffff [expr {$number - 65}]]
        } else {
            error "access_register_command->Unknown register"
        }
        #TODO: add custom registers support

        set command [expr {$command | $flags}]

        return $command
    }

    proc sc_jtaglib_execute_abstract_command { tap_num command } {
        sc_jtaglib_verbose "\[$tap_num\] execution of abstract command" 3

        sc_jtaglib_verbose "command=0x[format %x $command]"

        if {[sc_jtaglib_get_field $command 0xff000000] == 0} {
            set size_     [expr {8 << [sc_jtaglib_get_field $command 0x700000]}]
            set postexec_ [sc_jtaglib_get_field $command 0x40000]
            set transfer_ [sc_jtaglib_get_field $command 0x20000]
            set write_    [sc_jtaglib_get_field $command 0x10000]
            set regno_    [sc_jtaglib_get_field $command 0xffff]

            sc_jtaglib_verbose "access register; size=$size_; postexec=$postexec_; \
                transfer=$transfer_; write=$write_; regno=0x[format %X $regno_]"
        }

        set command_reg 0x17
        ocdjtag_riscv_dmi_write $tap_num $command_reg $command

        sc_jtaglib_verbose "\[$tap_num\] check_cmderr after execute command=$command" 3
        ocdjtag_riscv_check_cmderr $tap_num
    }

    proc sc_jtaglib_register_read_abstract { tap_num number size } {
        #TODO: add check for supporting csr and fpr

        if {$number >= 4162 && $number <= 4193} {
            error "register_read_abstract->Spec doesn't define abstract register numbers for vector registers"
        }

        set command [sc_jtaglib_access_register_command $tap_num $number $size 0x20000]

        sc_jtaglib_execute_abstract_command $tap_num $command
    }
    #end of list of copies of openocd C functions

    proc sc_jtaglib_get_aarsize { tap_num } {
        set xlen [ocdjtag_riscv_get_xlen $tap_num]
        return [expr {$xlen == 32 ? 2 : 3}]
    }

    proc sc_jtaglib_wait_abstractcs { tap_num } {
        set abstractcs [ocdjtag_riscv_get_abstractcs $tap_num]
        set timeout_ms [sc_jtaglib_get_op_latency]
        set start_time [clock milliseconds]
        set current_time $start_time

        while {[dict get $abstractcs busy] && ($current_time - $start_time < $timeout_ms)} {
            set abstractcs [ocdjtag_riscv_get_abstractcs $tap_num]
            set current_time [clock milliseconds]
        }

        if {($current_time - $start_time) >= $timeout_ms} {
            error "check_cmderr->Timed out during running abstract command"
        }
        return $abstractcs
    }
}

# Wait for DMI completion. Transport failures and timeouts raise Tcl errors.
proc ocdjtag_riscv_dmi_scan { tap_num address data op } {
    variable ::__SC_JTAGLIB_INTERNAL::DMI_ADDRESS_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::DMI_DATA_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::DMI_NOP
    variable ::__SC_JTAGLIB_INTERNAL::DMI_READ
    variable ::__SC_JTAGLIB_INTERNAL::DMI_WRITE

    set tap_info [__SC_JTAGLIB_INTERNAL::sc_jtaglib_get_tap_info $tap_num]

    set tap_name [dict get $tap_info name]
    set dmi_size [dict get $tap_info dmi_size]
    set dtmcs_idle [dict get $tap_info idle]

    if {$op != "read" && $op != "write" && $op != "nop"} {
        error "dmi_scan->Incorrect operation"
    }

    set shifted_address [expr {$address << $DMI_ADDRESS_SHIFT}]
    set shifted_data    [expr {$data << $DMI_DATA_SHIFT}]
    set dmi_op $DMI_NOP

    switch $op {
        nop     {set dmi_op $DMI_NOP}
        read    {set dmi_op $DMI_READ}
        write   {set dmi_op $DMI_WRITE}
        default {
            error "dmi_scan->Incorrect operation; unreachable"
        }
    }

    set dmi_val [expr {$shifted_address | $shifted_data | $dmi_op}]
    set hex_dmi_val 0x[format %x $dmi_val]

    set code [catch {
        __SC_JTAGLIB_INTERNAL::sc_jtaglib_dmi_scan_timeout \
            $tap_name $dmi_size $hex_dmi_val $dtmcs_idle
    } result options]
    if {$code} {
        set message "dmi_scan->TAP $tap_name request $hex_dmi_val: $result"
        if {$code == 1} {
            return -code error -errorinfo [dict get $options -errorinfo] $message
        }
        return -code $code $message
    }

    if {$op == "read"} {
        return $result
    }
}

proc ocdjtag_riscv_dmi_read { tap_num address } {
    variable ::__SC_JTAGLIB_INTERNAL::DMI_DATA_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::DMI_DATA_MASK

    set dmi_bitval [ocdjtag_riscv_dmi_scan $tap_num $address 0 read]

    return [expr {($dmi_bitval >> $DMI_DATA_SHIFT) & $DMI_DATA_MASK}]
}

proc ocdjtag_riscv_dmi_write { tap_num address data } {
    ocdjtag_riscv_dmi_scan $tap_num $address $data write
}

proc ocdjtag_riscv_get_dtmcs { tap_num } {
    variable ::__SC_JTAGLIB_INTERNAL::IR_DTMCS
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_DMIRESET
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_IDLE_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_IDLE_VALUE_MASK
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_DMISTAT_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_DMISTAT_VALUE_MASK
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_ABITS_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_ABITS_VALUE_MASK
    variable ::__SC_JTAGLIB_INTERNAL::DTMCS_VERSION_MASK

    set tap_info [__SC_JTAGLIB_INTERNAL::sc_jtaglib_get_tap_info $tap_num]

    set tap_name [dict get $tap_info name]

    irscan $tap_name $IR_DTMCS
    set dtmcs_bitval [format 0x%s [drscan $tap_name 32 0x0]]

    return [dict create \
        dmireset [expr {($dtmcs_bitval & $DTMCS_DMIRESET) != 0}] \
        idle     [expr {
            ($dtmcs_bitval >> $DTMCS_IDLE_SHIFT) &
            $DTMCS_IDLE_VALUE_MASK
        }] \
        dmistat  [expr {
            ($dtmcs_bitval >> $DTMCS_DMISTAT_SHIFT) &
            $DTMCS_DMISTAT_VALUE_MASK
        }] \
        abits    [expr {
            ($dtmcs_bitval >> $DTMCS_ABITS_SHIFT) &
            $DTMCS_ABITS_VALUE_MASK
        }] \
        version  [expr {$dtmcs_bitval & $DTMCS_VERSION_MASK}] \
        is_zero  [expr {$dtmcs_bitval == 0}] \
    ]
    # is_zero is not a field of register, it's created just for using in examine_hart function
}

# Activate low-level access and replace the cached discovery information.
proc ocdjtag_riscv_update_taps_info {} {
    global __JTAG_TAPS_INFO
    variable ::__SC_JTAGLIB_INTERNAL::DMI_ADDRESS_SHIFT
    set __JTAG_TAPS_INFO [dict create]
    # Without initialized targets, OpenOCD has no background polling to disable.
    if {[llength [info commands poll]]} {
        poll off
        echo "!!! WARNING: TARGET POLLING DISABLED FOR LOW-LEVEL JTAG !!!"
        echo "DEVICE ACCESS WITH POLLING ENABLED IS UNDEFINED BEHAVIOR."
        echo "Such calls are allowed only because this Tcl API cannot"
        echo "reliably detect and reject them. Keep polling off until"
        echo "all low-level JTAG work is finished."
    }

    set scan_chain_result [__SC_JTAGLIB_INTERNAL::sc_jtaglib_parse_scan_chain [scan_chain]]

    set tap_count [dict get $scan_chain_result tap_count]

    set taps_info [dict create tap_count $tap_count]

    for {set i 0} {$i < $tap_count} {incr i} {
        set tap_name [dict get $scan_chain_result tap_list $i]

        dict set taps_info $i name $tap_name

        set dtmcs [__SC_JTAGLIB_INTERNAL::sc_jtaglib_get_dtmcs_by_name $tap_name]

        dict set taps_info $i abits [dict get $dtmcs abits]
        dict set taps_info $i dmi_size \
            [expr {$DMI_ADDRESS_SHIFT + [dict get $dtmcs abits]}]
        dict set taps_info $i idle [dict get $dtmcs idle]
    }
    set __JTAG_TAPS_INFO $taps_info
    return
}

# Return the last successful discovery without accessing the device.
proc ocdjtag_riscv_get_taps_info {} {
    global __JTAG_TAPS_INFO

    if {![dict exists $__JTAG_TAPS_INFO tap_count]} {
        error "TAP information is not initialized; run ocdjtag_riscv_update_taps_info"
    }
    return $__JTAG_TAPS_INFO
}

#start of getters for DM registers

proc ocdjtag_riscv_get_dmstatus { tap_num } {
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reading dmstatus" 3

    set dmstatus_bitval [ocdjtag_riscv_dmi_read $tap_num 0x11]

    return [dict create \
        impebreak       [expr {($dmstatus_bitval >> 22) & 1}] \
        allhavereset    [expr {($dmstatus_bitval >> 19) & 1}] \
        anyhavereset    [expr {($dmstatus_bitval >> 18) & 1}] \
        allresumeack    [expr {($dmstatus_bitval >> 17) & 1}] \
        anyresumeack    [expr {($dmstatus_bitval >> 16) & 1}] \
        allnonexistent  [expr {($dmstatus_bitval >> 15) & 1}] \
        anynonexistent  [expr {($dmstatus_bitval >> 14) & 1}] \
        allunavail      [expr {($dmstatus_bitval >> 13) & 1}] \
        anyunavail      [expr {($dmstatus_bitval >> 12) & 1}] \
        allrunning      [expr {($dmstatus_bitval >> 11) & 1}] \
        anyrunning      [expr {($dmstatus_bitval >> 10) & 1}] \
        allhalted       [expr {($dmstatus_bitval >> 9) & 1}] \
        anyhalted       [expr {($dmstatus_bitval >> 8) & 1}] \
        authenticated   [expr {($dmstatus_bitval >> 7) & 1}] \
        authbusy        [expr {($dmstatus_bitval >> 6) & 1}] \
        hasresethaltreq [expr {($dmstatus_bitval >> 5) & 1}] \
        confstrptrvalid [expr {($dmstatus_bitval >> 4) & 1}] \
        version         [expr {$dmstatus_bitval & 0xf}] \
    ]
}

proc ocdjtag_riscv_get_dmcontrol { tap_num } {
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reading dmcontrol" 3

    set dtmcontrol_reg 0x10
    set dmcontrol_bitval [ocdjtag_riscv_dmi_read $tap_num $dtmcontrol_reg]

    return [dict create \
        haltreq      [expr {($dmcontrol_bitval >> 31) & 1}] \
        resumereq    [expr {($dmcontrol_bitval >> 30) & 1}] \
        ackhavereset [expr {($dmcontrol_bitval >> 28) & 1}] \
        hartreset    [expr {($dmcontrol_bitval >> 29) & 1}] \
        hasel        [expr {($dmcontrol_bitval >> 26) & 1}] \
        hartsel      [expr {($dmcontrol_bitval >> 6) & 0xfffff}] \
        dmactive     [expr {$dmcontrol_bitval & 1}] \
    ]
}

proc ocdjtag_riscv_get_hartinfo { tap_num } {
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reading hartinfo" 3

    set hartinfo_reg 0x12
    set hartinfo_bitval [ocdjtag_riscv_dmi_read $tap_num $hartinfo_reg]

    return [dict create \
        dataaccess [expr {($hartinfo_bitval >> 16) & 1}] \
        datasize   [expr {($hartinfo_bitval >> 12) & 0xf}] \
        dataaddr   [expr {$hartinfo_bitval & 0xfff}] \
    ]
}

proc ocdjtag_riscv_get_sbcs { tap_num } {
    variable ::__SC_JTAGLIB_INTERNAL::DM_SBCS
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBVERSION_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBVERSION_VALUE_MASK
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBACCESS_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBACCESS_VALUE_MASK
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBERROR_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBERROR_VALUE_MASK
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBASIZE_SHIFT
    variable ::__SC_JTAGLIB_INTERNAL::SBCS_SBASIZE_VALUE_MASK

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reading sbcs" 3

    set sbcs_bitval [ocdjtag_riscv_dmi_read $tap_num $DM_SBCS]

    return [dict create \
        sbversion       [expr {
            ($sbcs_bitval >> $SBCS_SBVERSION_SHIFT) &
            $SBCS_SBVERSION_VALUE_MASK
        }] \
        sbbusyerror     [expr {($sbcs_bitval >> 22) & 0x1}] \
        sbbusy          [expr {($sbcs_bitval >> 21) & 0x1}] \
        sbreadonaddr    [expr {($sbcs_bitval >> 20) & 0x1}] \
        sbaccess        [expr {
            ($sbcs_bitval >> $SBCS_SBACCESS_SHIFT) &
            $SBCS_SBACCESS_VALUE_MASK
        }] \
        sbautoincrement [expr {($sbcs_bitval >> 16) & 0x1}] \
        sbreadondata    [expr {($sbcs_bitval >> 15) & 0x1}] \
        sberror         [expr {
            ($sbcs_bitval >> $SBCS_SBERROR_SHIFT) &
            $SBCS_SBERROR_VALUE_MASK
        }] \
        sbasize         [expr {
            ($sbcs_bitval >> $SBCS_SBASIZE_SHIFT) &
            $SBCS_SBASIZE_VALUE_MASK
        }] \
        sbaccess128     [expr {($sbcs_bitval >> 4) & 0x1}] \
        sbaccess64      [expr {($sbcs_bitval >> 3) & 0x1}] \
        sbaccess32      [expr {($sbcs_bitval >> 2) & 0x1}] \
        sbaccess16      [expr {($sbcs_bitval >> 1) & 0x1}] \
        sbaccess8       [expr {$sbcs_bitval & 0x1}] \
    ]
}

proc ocdjtag_riscv_get_abstractcs { tap_num } {
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reading abstractcs" 3

    set abstractcs_reg 0x16
    set abstr_bitval [ocdjtag_riscv_dmi_read $tap_num $abstractcs_reg]

    return [dict create \
        progbufsize [expr {($abstr_bitval >> 24) & 0x1f}] \
        datacount   [expr {$abstr_bitval & 0xf}] \
        cmderr      [expr {($abstr_bitval >> 8) & 0x7}] \
        busy        [expr {($abstr_bitval >> 12) & 0x1}] \
    ]
}

#end of getter for DM registers

# Wait for abstract command completion and report any hardware error.
proc ocdjtag_riscv_check_cmderr { tap_num } {
    set abstractcs [__SC_JTAGLIB_INTERNAL::sc_jtaglib_wait_abstractcs $tap_num]
    set cmderr [dict get $abstractcs cmderr]

    if {$cmderr != 0} {
        error "cmderr=$cmderr"
    }
}

proc ocdjtag_riscv_clear_cmderr { tap_num } {
    set clear_cmderr_value [expr {0x7 << 8}]

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] clearing cmderr" 3

    set abstractcs_reg 0x16

    ocdjtag_riscv_dmi_write $tap_num $abstractcs_reg $clear_cmderr_value
}

#start of hart control commands

proc ocdjtag_riscv_halt_hart { tap_num } {
    set dmcontrol_val [expr {1 | 1 << 31}]

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] halt hart" 3

    set dmcontrol_reg 0x10
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmcontrol_val

    set timeout_ms [__SC_JTAGLIB_INTERNAL::sc_jtaglib_get_op_latency]
    set start [clock milliseconds]
    set cur $start

    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    while {[expr {([dict get $dmstatus anyhalted] == 0) && ($cur - $start < $timeout_ms)}]} {
        set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

        set cur [clock milliseconds]
    }

    if {($cur - $start) >= $timeout_ms} {
        error "halt_hart->Timed out during waiting state update after halt"
    }

    if {![dict get $dmstatus anyhalted]} {
        error "halt_hart->Halt isn't successful"
    }
}

proc ocdjtag_riscv_step_hart { tap_num } {
    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    if {![dict get $dmstatus allhalted]} {
        error "step->Target is not halted"
    }

    set xlen [ocdjtag_riscv_get_xlen $tap_num]
    set dcsr_reg 0x7b0
    set dcsr_val [ocdjtag_riscv_load_register $tap_num $dcsr_reg $xlen]
    #setting step bit
    set dcsr_val [expr {$dcsr_val | (1 << 2)}]
    ocdjtag_riscv_store_register $tap_num $dcsr_reg $dcsr_val $xlen

    ocdjtag_riscv_resume_hart $tap_num 1

    #clearing step bit
    set dcsr_val [ocdjtag_riscv_load_register $tap_num $dcsr_reg $xlen]
    set dcsr_val [expr {$dcsr_val & (0xffffffff & ~(1 << 2))}]
    ocdjtag_riscv_store_register $tap_num $dcsr_reg $dcsr_val $xlen
}

proc ocdjtag_riscv_resume_hart { tap_num {for_step 0} } {
    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    if {[dict get $dmstatus anyrunning]} {
        error "resume_hart->Target already running"
    }

    set dmcontrol_val [expr {1 | 1 << 30}]

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] resume hart" 3

    set dmcontrol_reg 0x10
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmcontrol_val

    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    if {![dict get $dmstatus anyrunning] && $for_step == 0} {
        error "resume_hart->Resume isn't successful"
    }

    if {![dict get $dmstatus anyresumeack]} {
        error "resume_hart->Resume acknowledgment isn't successful"
    }
}

proc ocdjtag_riscv_reset_halt_hart { tap_num } {
    set dmcontrol_reg 0x10

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: dmactive & haltreq" 3
    set dmi_val [expr {1 | 1 << 31}]
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmi_val

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: dmactive & ndmreset & haltreq" 3
    set dmi_val [expr {1 | 1 << 1 | 1 << 31}]
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmi_val

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: all/anyhavereset check" 3
    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    if {[dict get $dmstatus allhavereset] == 0 || [dict get $dmstatus anyhavereset] == 0} {
        error "all/anyhavereset check"
    }

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: dmactive & !ndmreset & haltreq" 3
    set dmi_val [expr {1 | 1 << 31}]
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmi_val

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: dmactive & ackhavereset & haltreq" 3
    set dmi_val [expr {1 | 1 << 28 | 1 << 31}]
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmi_val

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: dmactive & !ackhavereset & !haltreq" 3
    set dmi_val [expr {1}]
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmi_val

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset hart: !all/anyrunning & all/anyhalted check" 3
    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    if {[dict get $dmstatus allrunning] == 1 || [dict get $dmstatus anyrunning] == 1 || [dict get $dmstatus allhalted] == 0 || [dict get $dmstatus anyhalted] == 0} {
        error "!all/anyrunning & all/anyhalted check"
    }
}
#end of hart control commands

proc ocdjtag_riscv_reset_dm { tap_num } {
    set dmcontrol_reg 0x10

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset Debug Module:turning off" 3
    set dmcontrol_val 0x0
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmcontrol_val

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] reset Debug Module:turning on" 3
    set dmcontrol_val 0x1
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmcontrol_val
}

proc ocdjtag_riscv_examine_hart { tap_num } {
    global __JTAG_TAPS_INFO

    set dtmcontrol [ocdjtag_riscv_get_dtmcs $tap_num]

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "dtmcontrol: $dtmcontrol"

    if {[dict get $dtmcontrol is_zero]} {
        error "examine_hart->dtmcontrol is 0. Check JTAG connectivity/board power"
    }

    if {[dict get $dtmcontrol version] != 1} {
        error "examine_hart->Unsupported DTM version [dict get $dtmcontrol version]"
    }

    if {[dict get $__JTAG_TAPS_INFO tap_count] == 0} {
        error "examine_hart->No harts found"
    } else {
        __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "[dict get $__JTAG_TAPS_INFO tap_count] harts found"
    }

    ocdjtag_riscv_reset_dm $tap_num

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] writing dmcontrol to discover HARTSELLEN" 3

    set dmcontrol_reg 0x10
    set dmcontrol_bitval [expr {(1 << 26) | (((1 << 21) - 1) << 6) | 1}]
    ocdjtag_riscv_dmi_write $tap_num $dmcontrol_reg $dmcontrol_bitval

    set dmcontrol [ocdjtag_riscv_get_dmcontrol $tap_num]
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "dmcontrol: $dmcontrol"

    if {![dict get $dmcontrol dmactive]} {
        error "examine_hart->Debug Module is not become active"
    }

    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]

    set dm_version [dict get $dmstatus version]

    if {$dm_version != 2 && $dm_version != 3} {
        error "OpenOCD only supports Debug Module version 2 (0.13) and 3 (1.0), not $dm_version"
    }

    if {[dict get $dmcontrol hartsel] == 0} {
        __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "hartsellen=0"
    } else {
        set hartsellen 0
        set hartsel [dict get $dmcontrol hartsel]

        while {$hartsel != 0} {
            set hartsellen [expr {$hartsellen + 1}]
            set hartsel [expr {$hartsel >> 1}]
        }

        __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "hartsellen=$hartsellen"
    }

    set hartinfo [ocdjtag_riscv_get_hartinfo $tap_num]
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "hartinfo: $hartinfo"

    if {[dict get $dmstatus authenticated] == 0} {
        error "examine_hart->Debugger is not authenticated to target Debug Module. dmstatus: $dmstatus"
    }

    set sbcs [ocdjtag_riscv_get_sbcs $tap_num]
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "sbcs: $sbcs"

    set abstracts [ocdjtag_riscv_get_abstractcs $tap_num]
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "abstracts: $abstracts"

    if {[dict get $abstracts progbufsize] + [dict get $dmstatus impebreak] < 2} {
        __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "We won't be able to execute fence instructions on this \
        target. Memory may not always appear consistent" 1
    }

    ocdjtag_riscv_halt_hart $tap_num

    set xlen [ocdjtag_riscv_get_xlen $tap_num]
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "xlen: $xlen"
}

#functions for register access

# Discover the 32/64-bit debug register width of the selected, halted hart.
# Read x5 (t0) without changing it; the DM's command/data registers are used.
proc ocdjtag_riscv_get_xlen { tap_num } {
    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]
    if {![dict get $dmstatus allhalted]} {
        error "get_xlen->Target should be halted"
    }
    # Do not confuse a pre-existing error with a failed width probe.
    ocdjtag_riscv_check_cmderr $tap_num

    foreach xlen {64 32} {
        set command [__SC_JTAGLIB_INTERNAL::sc_jtaglib_access_register_command \
            $tap_num 5 $xlen 0x20000]
        ocdjtag_riscv_dmi_write $tap_num 0x17 $command
        set abstractcs [__SC_JTAGLIB_INTERNAL::sc_jtaglib_wait_abstractcs $tap_num]
        set cmderr [dict get $abstractcs cmderr]
        if {$cmderr == 0} {
            return $xlen
        }
        # A too-wide access can be unsupported or fault during execution.
        # Verify the narrower access instead of assuming either error means RV32.
        if {$xlen == 64 && ($cmderr == 2 || $cmderr == 3)} {
            ocdjtag_riscv_clear_cmderr $tap_num
            ocdjtag_riscv_check_cmderr $tap_num
        } else {
            error "cmderr=$cmderr"
        }
    }
}

# XLEN must be supplied as 32 or 64; reading a register never probes a GPR.
# The DM decides whether the requested register is accessible while running.
proc ocdjtag_riscv_load_register { tap_num reg_num xlen } {
    if {![string is integer -strict $xlen] || ($xlen != 32 && $xlen != 64)} {
        error "load_register->XLEN must be 32 or 64 bits: \"$xlen\""
    }
    set aarsize [expr {$xlen == 32 ? 2 : 3}]

    set data0_register 0x4
    set data1_register 0x5
    set command_register 0x17

    set command_data [expr {($aarsize << 20) | (1 << 17) | $reg_num}]
    ocdjtag_riscv_dmi_write $tap_num $command_register $command_data

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load from register $reg_num" 3
    ocdjtag_riscv_check_cmderr $tap_num

    set load_result [ocdjtag_riscv_dmi_read $tap_num $data0_register]

    if {$aarsize == 3} {
        set high [ocdjtag_riscv_dmi_read $tap_num $data1_register]
        set load_result [expr {$high << 32 | $load_result}]
    }

    set load_result 0x[format %x $load_result]

    return $load_result
}

proc ocdjtag_riscv_store_register { tap_num reg_num data xlen } {
    if {![string is integer -strict $xlen] || ($xlen != 32 && $xlen != 64)} {
        error "store_register->XLEN must be 32 or 64 bits: \"$xlen\""
    }
    if {![string is integer -strict $data]} {
        error "store_register->incorrect data: should be integer value"
    }

    if {$data < 0} {
        error "store_register->incorrect data: should be more than 0"
    }

    set aarsize [expr {$xlen == 32 ? 2 : 3}]

    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]
    set allhalted [dict get $dmstatus allhalted]

    if {$allhalted == 0} {
        error "store_register->Target should be halted"
    }

    set data0_register 0x4
    set data1_register 0x5
    set command_register 0x17

    set block0_data [expr {$data & 0xffffffff}]
    set block1_data [expr {$data >> 32}]

    ocdjtag_riscv_dmi_write $tap_num $data0_register $block0_data
    if {$aarsize == 3} {
        ocdjtag_riscv_dmi_write $tap_num $data1_register $block1_data
    }

    set command_data [expr {($aarsize << 20) | (1 << 16) | (1 << 17) | $reg_num}]
    ocdjtag_riscv_dmi_write $tap_num $command_register $command_data

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store $data to register $reg_num" 3
    ocdjtag_riscv_check_cmderr $tap_num
}

#functions for memory access using program buffer

proc ocdjtag_riscv_load_memory { tap_num address size } {
    if {$size != 32} {
        error "load_memory->Unsupported size(only 32 bit is supported)"
    }

    set load_result 0

    # getting a registers size
    set aarsize [__SC_JTAGLIB_INTERNAL::sc_jtaglib_get_aarsize $tap_num]

    set abstractcs [ocdjtag_riscv_get_abstractcs $tap_num]
    set progbuf_size [dict get $abstractcs progbufsize]

    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]
    set impebreak [dict get $dmstatus impebreak]
    set allhalted [dict get $dmstatus allhalted]

    if {$progbuf_size < 1} {
        error "load_memory->Need at least 1 program buffer size"
    }

    if {$progbuf_size == 1 && $impebreak == 0} {
        error "load_memory->Need at least 2 program buffer size"
    }

    if {$allhalted == 0} {
        error "load_memory->Target should be halted"
    }

    set progbuf0_register 0x20
    set progbuf1_register 0x21

    # lw s0, 0(s0)
    set lw_opcode 0x42403
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:store lw opcode=$lw_opcode" 3
    ocdjtag_riscv_dmi_write $tap_num $progbuf0_register $lw_opcode

    if {$progbuf_size > 1} {
        # ebreak instr
        set ebreak_opcode 0x100073
        __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:store ebreak opcode=$ebreak_opcode" 3
        ocdjtag_riscv_dmi_write $tap_num $progbuf1_register $ebreak_opcode
    }

    set command_register 0x17
    set data0_register 0x4
    set data1_register 0x5

    set address_block0 [expr {$address & 0xffffffff}]
    set address_block1 [expr {($address >> 32) & 0xffffffff}]

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:store address=$address" 3
    ocdjtag_riscv_dmi_write $tap_num $data0_register $address_block0

    if {$aarsize == 3} {
        ocdjtag_riscv_dmi_write $tap_num $data1_register $address_block1
    }

    set s0_register 0x1008

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:store address to s0(with executing progbuf)" 3
    set command_data [expr {($aarsize << 20) | (1 << 16) | (1 << 17) | (1 << 18) | $s0_register}]
    ocdjtag_riscv_dmi_write $tap_num $command_register $command_data

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:check_cmderr after execute command=0x[format %x $command_data]" 3
    ocdjtag_riscv_check_cmderr $tap_num

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:load value from s0 to data0" 3
    set command_data [expr {($aarsize << 20) | (1 << 17) | $s0_register}]
    ocdjtag_riscv_dmi_write $tap_num $command_register $command_data

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:check_cmderr after execute command=0x[format %x $command_data]" 3
    ocdjtag_riscv_check_cmderr $tap_num

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] load_memory:loading value from data0" 3
    set load_result [ocdjtag_riscv_dmi_read $tap_num $data0_register]

    set load_result 0x[format %x $load_result]

    return $load_result
}

proc ocdjtag_riscv_store_memory { tap_num address size data} {
    if {$size != 32} {
        error "store_memory->Unsupported size(only 32 bit is supported)"
    }

    if {![string is integer -strict $data]} {
        error "store_memory->incorrect data: should be integer value"
    }

    if {$data < 0} {
        error "store_memory->incorrect data: should be more than 0"
    }

    # getting a registers size
    set aarsize [__SC_JTAGLIB_INTERNAL::sc_jtaglib_get_aarsize $tap_num]

    set abstractcs [ocdjtag_riscv_get_abstractcs $tap_num]
    set progbuf_size [dict get $abstractcs progbufsize]

    set dmstatus [ocdjtag_riscv_get_dmstatus $tap_num]
    set impebreak [dict get $dmstatus impebreak]
    set allhalted [dict get $dmstatus allhalted]

    if {$allhalted == 0} {
        error "store_memory->Target should be halted"
    }

    if {$progbuf_size < 1} {
        error "store_memory->Need at least 1 program buffer size"
    }

    if {$progbuf_size == 1 && $impebreak == 0} {
        error "store_memory->Need at least 2 program buffer size"
    }

    set progbuf0_register 0x20
    set progbuf1_register 0x21

    # sw s1, 0(s0)
    set sw_opcode 0x942023
    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:store sw opcode=$sw_opcode" 3
    ocdjtag_riscv_dmi_write $tap_num $progbuf0_register $sw_opcode

    if {$progbuf_size > 1} {
        # ebreak instr
        set ebreak_opcode 0x100073
        __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:store ebreak opcode=$ebreak_opcode" 3
        ocdjtag_riscv_dmi_write $tap_num $progbuf1_register $ebreak_opcode
    }

    set command_register 0x17
    set data0_register 0x4
    set data1_register 0x5

    set address_block0 [expr {$address & 0xffffffff}]
    set address_block1 [expr {($address >> 32) & 0xffffffff}]

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:store memory address=$address" 3
    ocdjtag_riscv_dmi_write $tap_num $data0_register $address_block0

    if {$aarsize == 3} {
        ocdjtag_riscv_dmi_write $tap_num $data1_register $address_block1
    }

    set s0_register 0x1008
    set s1_register 0x1009

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:store address to s0" 3
    set command_data [expr {($aarsize << 20) | (1 << 16) | (1 << 17) | $s0_register}]
    ocdjtag_riscv_dmi_write $tap_num $command_register $command_data

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:check cmderr after execute command=$command_data" 3
    ocdjtag_riscv_check_cmderr $tap_num

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:store block to data0" 3
    set data_part [expr {$data & 0xffffffff}]
    ocdjtag_riscv_dmi_write $tap_num $data0_register $data_part

    if {$aarsize == 3} {
        ocdjtag_riscv_dmi_write $tap_num $data1_register 0x0
    }

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:store block to s1(with executing progbuf)" 3
    set command_data [expr {($aarsize << 20) | (1 << 16) | (1 << 17) | (1 << 18) | $s1_register}]
    ocdjtag_riscv_dmi_write $tap_num $command_register $command_data

    __SC_JTAGLIB_INTERNAL::sc_jtaglib_verbose "\[$tap_num\] store_memory:check cmderr after execute command=$command_data" 3
    ocdjtag_riscv_check_cmderr $tap_num
}
