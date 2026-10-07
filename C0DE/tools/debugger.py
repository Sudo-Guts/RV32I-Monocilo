#!/usr/bin/env python3
"""RV32I Debugger: UART / WISHBONE B4 Classic, protocolo versión 1.0."""

from __future__ import annotations

import csv
import queue
from collections import deque
from threading import Event, RLock
from functools import wraps
import binascii
import struct
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    serial = None
    list_ports = None

import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter import font as tkfont


# =============================================================================
# Excepciones
# =============================================================================

class DebuggerError(Exception):
    """Error base del debugger."""


class DebuggerTimeout(DebuggerError):
    """No llegó una respuesta completa antes del timeout."""


class ProtocolError(DebuggerError):
    """La FPGA respondió con un valor que no corresponde al protocolo."""


class HexFileError(DebuggerError):
    """El archivo .hex no tiene el formato esperado."""


# =============================================================================
# Información de estado
# =============================================================================

@dataclass
class CPUSnapshot:
    pc: int
    out: int
    instr: int
    last_pc: int
    last_out: int
    last_instr: int


@dataclass
class LoadReport:
    filename: str
    base_address: int
    original_bytes: int
    programmed_bytes: int
    words: int
    verified: bool


# =============================================================================
# Backend de comunicación
# =============================================================================

class WishboneError(DebuggerError):
    """Transacción terminada por ERR o por el watchdog del crossbar."""


def _serialized(method):
    @wraps(method)
    def call(self, *args, **kwargs):
        with self._lock:
            return method(self, *args, **kwargs)
    return call


class RV32IDebugger:
    IMEM_BASE = 0x00000000
    DMEM_BASE = 0x00010000
    LOADER_BASE = 0x10000000
    DEBUG_BASE = 0x10001000
    IMEM_MAX_ADDRESS = 0x0000FFFC
    DEVICE_ID = 0x52563332
    INTERFACE_VERSION = 0x00010000
    READ, WRITE = 0, 1
    L_TARGET, L_DATA, L_SEL = 0x00, 0x04, 0x08
    L_WRITE, L_READ, L_STATUS, L_RDATA, L_ERROR = 0x0C, 0x10, 0x14, 0x18, 0x1C
    D_STATUS, D_HALT, D_RUN, D_STEP, D_RESET = 0x00, 0x04, 0x08, 0x0C, 0x10
    D_PC, D_INSTR, D_WB, D_REG_INDEX, D_REG_DATA = 0x14, 0x18, 0x1C, 0x20, 0x24
    D_LAST_PC, D_LAST_INSTR, D_LAST_WB = 0x28, 0x2C, 0x30
    D_ID, D_IMEM_BYTES, D_DMEM_BYTES, D_VERSION, D_LAST_FAULT = 0x34, 0x38, 0x3C, 0x40, 0x44

    def __init__(self, port: Optional[str] = None, baudrate: int = 57600,
                 timeout: float = 1.0):
        if baudrate <= 0 or timeout <= 0:
            raise ValueError("Baudrate y timeout deben ser positivos.")
        self.port, self.baudrate, self.timeout = port, baudrate, timeout
        self.ser = None
        self.running = False
        self.imem_bytes = self.dmem_bytes = None
        self._sequence = 0
        self._faulted = False
        self._lock = RLock()

    @property
    def connected(self) -> bool:
        return self.ser is not None and self.ser.is_open

    @_serialized
    def connect(self, port: Optional[str] = None) -> None:
        if serial is None:
            raise DebuggerError("Instala PySerial: python -m pip install pyserial")
        if self.connected:
            return
        if port is not None:
            self.port = port
        if not self.port:
            raise DebuggerError("Selecciona un puerto serial.")
        try:
            self.ser = serial.Serial(self.port, self.baudrate, bytesize=8, parity="N",
                                     stopbits=1, timeout=min(0.05, self.timeout),
                                     write_timeout=self.timeout, xonxoff=False,
                                     rtscts=False, dsrdtr=False)
            # Supera el timeout de una trama parcial en el receptor del FPGA.
            time.sleep(max(0.15, 120.0 / self.baudrate))
            self.ser.reset_input_buffer()
            self._sequence = 0
            self._faulted = False
            self.imem_bytes = self.dmem_bytes = None
        except (OSError, serial.SerialException) as exc:
            if self.ser is not None:
                self.ser.close()
            self.ser = None
            raise DebuggerError(f"No se pudo abrir {self.port}: {exc}") from exc

    @_serialized
    def close(self) -> None:
        if self.ser is not None:
            try:
                self.ser.close()
            finally:
                self.ser = None

    def _require_connection(self) -> None:
        if not self.connected:
            raise DebuggerError("El puerto serial está cerrado.")
        if self._faulted:
            raise ProtocolError("Reconecta el puerto para resincronizar UART. No se repitió la operación.")

    @staticmethod
    def crc16(data: bytes) -> int:
        return binascii.crc_hqx(data, 0xFFFF)

    def _read_exact(self, count: int, deadline: float) -> bytes:
        result = bytearray()
        while len(result) < count:
            if time.monotonic() >= deadline:
                raise DebuggerTimeout("Timeout UART; el resultado de la operación no está confirmado.")
            result.extend(self.ser.read(count - len(result)))
        return bytes(result)

    @_serialized
    def _transfer(self, address: int, data: int = 0, sel: int = 0xF,
                  write: bool = False) -> int:
        if not isinstance(address, int) or not 0 <= address <= 0xFFFFFFFC or address & 3:
            raise ValueError("ADR debe ser una dirección de 32 bits alineada a 4 bytes.")
        if not isinstance(data, int) or not 0 <= data <= 0xFFFFFFFF:
            raise ValueError("DAT debe estar entre 0 y 0xFFFFFFFF.")
        if not isinstance(sel, int) or not 1 <= sel <= 0xF:
            raise ValueError("SEL debe estar entre 1 y 0xF.")
        self._require_connection()
        seq = self._sequence
        self._sequence = (seq + 1) & 0xFF
        body = struct.pack("<BBBII", seq, self.WRITE if write else self.READ,
                           sel, address, data if write else 0)
        packet = b"\xA5\x5A" + body + struct.pack("<H", self.crc16(body))
        try:
            deadline = time.monotonic() + self.timeout
            if self.ser.write(packet) != len(packet):
                raise ProtocolError("Escritura UART incompleta; no se reintentó.")
            # Buscar cabecera sin vaciar el buffer ni descartar una respuesta válida.
            prefix = 0
            while prefix < 2:
                byte = self._read_exact(1, deadline)[0]
                if prefix == 0:
                    prefix = 1 if byte == 0x5A else 0
                elif byte == 0xA5:
                    prefix = 2
                else:
                    prefix = 1 if byte == 0x5A else 0
            reply = self._read_exact(8, deadline)
            if self.crc16(reply[:6]) != int.from_bytes(reply[6:], "little"):
                raise ProtocolError("CRC incorrecto en la respuesta UART; operación sin confirmar.")
            rx_seq, status, value = struct.unpack("<BBI", reply[:6])
            if rx_seq != seq:
                raise ProtocolError(f"Respuesta fuera de secuencia: {rx_seq}, se esperaba {seq}.")
            if status not in range(5):
                raise ProtocolError(f"Estado UART desconocido: 0x{status:02X}.")
            if (write or status) and value != 0:
                raise ProtocolError("La respuesta contiene DAT inválido para su estado.")
        except (DebuggerError, OSError) as exc:
            self._faulted = True
            if isinstance(exc, DebuggerError):
                raise
            raise ProtocolError(f"Fallo de transporte UART: {exc}") from exc
        if status == 1:
            raise ProtocolError("La FPGA rechazó el formato de la solicitud; no hubo acceso Wishbone.")
        if status == 2:
            raise ProtocolError("La FPGA rechazó el CRC de la solicitud; no hubo acceso Wishbone.")
        if status in (3, 4):
            reason = "ERR" if status == 3 else "timeout del crossbar"
            raise WishboneError(f"Wishbone {reason} en ADR=0x{address:08X}; sin reintentos.")
        return value

    def read(self, address: int, sel: int = 0xF) -> int:
        return self._transfer(address, sel=sel)

    def write(self, address: int, data: int, sel: int = 0xF) -> None:
        self._transfer(address, data, sel, True)

    @_serialized
    def ping(self) -> bool:
        if self.read(self.DEBUG_BASE + self.D_ID) != self.DEVICE_ID:
            raise ProtocolError("Identificador de FPGA incompatible.")
        if self.read(self.DEBUG_BASE + self.D_VERSION) != self.INTERFACE_VERSION:
            raise ProtocolError("Versión del protocolo incompatible.")
        self.imem_bytes = self.read(self.DEBUG_BASE + self.D_IMEM_BYTES)
        self.dmem_bytes = self.read(self.DEBUG_BASE + self.D_DMEM_BYTES)
        if any(size < 4 or size > 65536 or size & (size - 1)
               for size in (self.imem_bytes, self.dmem_bytes)):
            raise ProtocolError("Capacidades de memoria inválidas.")
        self.read_status()
        return True

    def read_status(self) -> int:
        status = self.read(self.DEBUG_BASE + self.D_STATUS)
        self.running = bool(status & 1)
        return status

    def _wait_halted(self) -> None:
        deadline = time.monotonic() + self.timeout
        while not (self.read_status() & 2):
            if time.monotonic() >= deadline:
                raise DebuggerTimeout("La CPU no confirmó HALT.")
            time.sleep(0.001)

    @_serialized
    def halt(self) -> None:
        self.write(self.DEBUG_BASE + self.D_HALT, 1)
        self._wait_halted()

    @_serialized
    def reset(self) -> None:
        self.halt()
        self.write(self.DEBUG_BASE + self.D_RESET, 1)
        self._wait_halted()

    @_serialized
    def step(self) -> None:
        if not self.read_status() & 2:
            raise DebuggerError("Detén la CPU antes de ejecutar STEP.")
        self.write(self.DEBUG_BASE + self.D_STEP, 1)
        self._wait_halted()

    @_serialized
    def run(self) -> None:
        self.write(self.DEBUG_BASE + self.D_RUN, 1)
        if not self.read_status() & 1:
            raise DebuggerError("La CPU no confirmó RUN.")

    def read_pc(self) -> int:
        return self.read(self.DEBUG_BASE + self.D_PC)

    def read_out(self) -> int:
        return self.read(self.DEBUG_BASE + self.D_WB)

    def read_instr(self) -> int:
        return self.read(self.DEBUG_BASE + self.D_INSTR)

    def read_last_pc(self) -> int:
        return self.read(self.DEBUG_BASE + self.D_LAST_PC)

    def read_last_out(self) -> int:
        return self.read(self.DEBUG_BASE + self.D_LAST_WB)

    def read_last_instr(self) -> int:
        return self.read(self.DEBUG_BASE + self.D_LAST_INSTR)

    def _ensure_halted(self, halt_if_running: bool) -> None:
        if not self.read_status() & 2:
            if halt_if_running:
                self.halt()
            else:
                raise DebuggerError("La CPU debe estar detenida para esta operación.")

    @_serialized
    def snapshot(self, halt_if_running: bool = True) -> CPUSnapshot:
        self._ensure_halted(halt_if_running)
        return CPUSnapshot(self.read_pc(), self.read_out(), self.read_instr(),
                           self.read_last_pc(), self.read_last_out(), self.read_last_instr())

    @_serialized
    def read_register(self, index: int) -> int:
        if not 0 <= index < 32:
            raise ValueError("Índice de registro fuera de 0..31.")
        self.write(self.DEBUG_BASE + self.D_REG_INDEX, index)
        return self.read(self.DEBUG_BASE + self.D_REG_DATA)

    @_serialized
    def read_all_registers(self, halt_if_running: bool = True) -> list[int]:
        self._ensure_halted(halt_if_running)
        return [self.read_register(index) for index in range(32)]

    @classmethod
    def _validate_imem_address(cls, address: int) -> None:
        if not isinstance(address, int) or not cls.IMEM_BASE <= address <= cls.IMEM_MAX_ADDRESS or address & 3:
            raise ValueError("Dirección IMEM fuera de 0x00000000..0x0000FFFC o sin alinear.")

    def _check_memory(self, address: int, size: int, data_memory: bool = False) -> None:
        if self.imem_bytes is None or self.dmem_bytes is None:
            self.ping()
        capacity = self.dmem_bytes if data_memory else self.imem_bytes
        if address < 0 or address & 3 or size <= 0 or address + size > capacity:
            raise ValueError(f"El rango solicitado excede la memoria de {capacity} bytes o no está alineado.")

    @_serialized
    def _memory_access(self, address: int, data: int = 0, write: bool = False,
                       sel: int = 0xF) -> int:
        # Configurar no produce efectos en memoria; START es el único disparador.
        if not 0 <= data <= 0xFFFFFFFF or not 1 <= sel <= 15:
            raise ValueError("DAT o SEL fuera de rango.")
        self.write(self.LOADER_BASE + self.L_TARGET, address)
        if write:
            self.write(self.LOADER_BASE + self.L_DATA, data)
        self.write(self.LOADER_BASE + self.L_SEL, sel)
        self.write(self.LOADER_BASE + (self.L_WRITE if write else self.L_READ), 1)
        deadline = time.monotonic() + self.timeout
        while True:
            status = self.read(self.LOADER_BASE + self.L_STATUS)
            if not status & 1 and status & 2:
                break
            if time.monotonic() >= deadline:
                raise DebuggerTimeout("El program loader no confirmó el fin del acceso.")
            time.sleep(0.001)
        if status & 4:
            error = self.read(self.LOADER_BASE + self.L_ERROR)
            raise WishboneError(f"Program loader: {'timeout' if error == 2 else 'ERR'} en 0x{address:08X}.")
        return 0 if write else self.read(self.LOADER_BASE + self.L_RDATA)

    @_serialized
    def read_imem(self, address: int) -> int:
        self._check_memory(address, 4)
        return self._memory_access(self.IMEM_BASE + address)

    @_serialized
    def write_imem(self, address: int, data: int, sel: int = 0xF) -> None:
        self._check_memory(address, 4)
        self._memory_access(self.IMEM_BASE + address, data, True, sel)

    @_serialized
    def read_dmem(self, address: int) -> int:
        self._check_memory(address, 4, True)
        return self._memory_access(self.DMEM_BASE + address)

    @_serialized
    def write_dmem(self, address: int, data: int, sel: int = 0xF) -> None:
        self._check_memory(address, 4, True)
        self._memory_access(self.DMEM_BASE + address, data, True, sel)

    @_serialized
    def dump_imem(self, start_address: int = 0, word_count: int = 256,
                  progress: Optional[Callable[[int, int, str], None]] = None,
                  cancel: Optional[Event] = None) -> list[tuple[int, int]]:
        self._check_memory(start_address, word_count * 4)
        self._ensure_halted(False)
        words = []
        for index in range(word_count):
            if cancel is not None and cancel.is_set():
                raise DebuggerError("Lectura de IMEM interrumpida.")
            address = start_address + index * 4
            words.append((address, self.read_imem(address)))
            if progress:
                progress(index + 1, word_count, "Leyendo IMEM")
        return words

    @staticmethod
    def parse_hex_file(path: str | Path) -> tuple[int, bytes]:
        """
        Lee archivos .hex en formato de bytes o palabras de 32 bits.

        Formato por bytes:
            93
            00
            50
            00

        También acepta varios bytes por línea:
            93 00 50 00

        Formato por palabras de 32 bits:
            00500093
            00300113
            FFF00193

        Las palabras de 32 bits se convierten internamente a bytes
        little-endian antes de programar la IMEM. Por ejemplo:

            00500093  ->  93 00 50 00

        Se pueden mezclar bytes y palabras en un mismo archivo.

        También acepta directivas tipo readmemh/Verilog:
            @00000000
            00500093
            00300113

        La dirección de una directiva @ se interpreta como dirección de byte,
        igual que las direcciones manejadas por el protocolo de la IMEM.

        Comentarios aceptados:
            # comentario
            ; comentario
            // comentario

        También se admite el prefijo 0x:
            0x93
            0x00500093

        Devuelve:
            (dirección_base, bytes_del_archivo)
        """
        path = Path(path)

        if not path.exists():
            raise HexFileError(f"No existe el archivo: {path}")

        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="latin-1")

        memory = {}
        current_address = 0

        def store_byte(value: int, line_number: int) -> None:
            nonlocal current_address

            if current_address > 0xFFFF:
                raise HexFileError(
                    f"Línea {line_number}: dirección fuera de la ventana IMEM de 64 KiB."
                )

            if current_address in memory:
                raise HexFileError(
                    f"Línea {line_number}: la dirección "
                    f"0x{current_address:08X} aparece más de una vez."
                )

            memory[current_address] = value & 0xFF
            current_address += 1

        for line_number, original_line in enumerate(text.splitlines(), 1):
            line = original_line

            # Retirar comentarios.
            comment_positions = [
                pos for marker in ("//", "#", ";")
                if (pos := line.find(marker)) >= 0
            ]
            if comment_positions:
                line = line[:min(comment_positions)]

            line = line.replace(",", " ").strip()

            if not line:
                continue

            for original_token in line.split():
                token = original_token

                if token.startswith("@"):
                    address_text = token[1:]

                    if not address_text or not re.fullmatch(
                        r"[0-9A-Fa-f]+",
                        address_text,
                    ):
                        raise HexFileError(
                            f"Línea {line_number}: directiva inválida '{token}'."
                        )

                    current_address = int(address_text, 16)

                    if current_address > 0xFFFF:
                        raise HexFileError(
                            f"Línea {line_number}: dirección fuera de la ventana IMEM de 64 KiB."
                        )

                    continue

                if token.lower().startswith("0x"):
                    token = token[2:]

                # Byte hexadecimal: 0 .. FF
                if re.fullmatch(r"[0-9A-Fa-f]{1,2}", token):
                    store_byte(int(token, 16), line_number)
                    continue

                # Palabra de 32 bits: exactamente 8 dígitos hexadecimales.
                # Se convierte a cuatro bytes little-endian para que
                # load_hex() reconstruya exactamente el mismo valor con
                # int.from_bytes(..., "little").
                if re.fullmatch(r"[0-9A-Fa-f]{8}", token):
                    word = int(token, 16)

                    for value in word.to_bytes(4, byteorder="little"):
                        store_byte(value, line_number)

                    continue

                raise HexFileError(
                    f"Línea {line_number}: '{original_token}' no es un byte "
                    "hexadecimal (00..FF) ni una palabra de 32 bits "
                    "(XXXXXXXX) válida."
                )

        if not memory:
            raise HexFileError("El archivo .hex no contiene datos.")

        base = min(memory)
        end = max(memory)

        if end - base + 1 > 65536:
            raise HexFileError("La imagen excede la ventana de IMEM de 64 KiB.")

        # Para mantener el cargador determinista, rellenamos huecos hacia
        # adelante con cero. En archivos normales no habrá huecos.
        image = bytes(memory.get(address, 0) for address in range(base, end + 1))

        return base, image

    @_serialized
    def load_hex(
        self,
        path: str | Path,
        base_address: Optional[int] = None,
        verify: bool = True,
        reset_after: bool = True,
        progress: Optional[Callable[[int, int, str], None]] = None,
        cancel: Optional[Event] = None,
    ) -> LoadReport:
        file_base, image = self.parse_hex_file(path)

        if base_address is None:
            base_address = file_base

        if base_address & 0x3:
            raise HexFileError(
                f"La dirección base 0x{base_address:08X} no está "
                "alineada a 4 bytes."
            )

        original_size = len(image)

        # La IMEM se programa por palabras de 32 bits.
        if len(image) % 4:
            pad = 4 - (len(image) % 4)
            image += bytes(pad)

        self._validate_imem_address(base_address)

        self._check_memory(base_address, len(image))

        # Si estaba ejecutando, detenemos antes de programar.
        self._ensure_halted(True)

        words = []
        total = (len(image) // 4) * (2 if verify else 1)
        completed = 0

        for index, offset in enumerate(range(0, len(image), 4)):
            address = base_address + offset
            word = int.from_bytes(image[offset:offset + 4], "little")
            if cancel is not None and cancel.is_set():
                raise DebuggerError("Carga interrumpida: IMEM puede contener un programa parcial.")
            try:
                self.write_imem(address, word)
            except DebuggerError as exc:
                total_words = len(image) // 4
                raise DebuggerError(
                    f"Fallo escribiendo palabra {index + 1}/{total_words} "
                    f"en 0x{address:08X}: {exc}"
                ) from exc
            words.append((address, word))
            completed += 1
            if progress:
                progress(completed, total, "Escribiendo IMEM")

        if verify:
            for index, (address, expected) in enumerate(words):
                if cancel is not None and cancel.is_set():
                    raise DebuggerError("Verificación interrumpida; programa sin verificar.")
                try:
                    actual = self.read_imem(address)
                except DebuggerError as exc:
                    total_words = len(image) // 4
                    raise DebuggerError(
                        f"Fallo verificando palabra {index + 1}/{total_words} "
                        f"en 0x{address:08X}: {exc}"
                    ) from exc

                if actual != expected:
                    raise ProtocolError(
                        f"Error de verificación en 0x{address:08X}: "
                        f"escrito 0x{expected:08X}, "
                        f"leído 0x{actual:08X}."
                    )

                completed += 1
                if progress:
                    progress(completed, total, "Verificando IMEM")

        if reset_after:
            self.reset()

        return LoadReport(
            filename=str(path),
            base_address=base_address,
            original_bytes=original_size,
            programmed_bytes=len(image),
            words=len(words),
            verified=verify,
        )


# =============================================================================
# Decodificacion local. Referencia: RV32I v2.1 (RISC-V International)
# https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html
# Interpretar una instruccion no implica que el RTL implemente toda la ISA.
# =============================================================================

ABI_NAMES = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0/fp", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]


def signed(value: int, bits: int = 32) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


@dataclass(frozen=True)
class DecodedInstruction:
    text: str
    kind: str = "?"
    rd: Optional[int] = None
    rs1: Optional[int] = None
    rs2: Optional[int] = None
    immediate: Optional[int] = None
    target: Optional[int] = None


def decode_instruction(word: int, pc: int = 0) -> DecodedInstruction:
    """RV32I sin pseudoinstrucciones. Codificaciones desconocidas: .word."""
    word &= 0xFFFFFFFF
    op, rd, f3 = word & 127, (word >> 7) & 31, (word >> 12) & 7
    rs1, rs2, f7 = (word >> 15) & 31, (word >> 20) & 31, word >> 25
    imm_i = signed(word >> 20, 12)
    unknown = DecodedInstruction(f".word 0x{word:08X}")
    if op == 0x33:
        names = {(0, 0): "add", (32, 0): "sub", (0, 1): "sll",
                 (0, 2): "slt", (0, 3): "sltu", (0, 4): "xor",
                 (0, 5): "srl", (32, 5): "sra", (0, 6): "or", (0, 7): "and"}
        name = names.get((f7, f3))
        return DecodedInstruction(f"{name} x{rd}, x{rs1}, x{rs2}", "R", rd, rs1, rs2) if name else unknown
    if op == 0x13:
        names = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
        name, imm = names.get(f3), imm_i
        if f3 == 1 and f7 == 0:
            name, imm = "slli", rs2
        elif f3 == 5 and f7 in (0, 32):
            name, imm = ("srai" if f7 else "srli"), rs2
        return DecodedInstruction(f"{name} x{rd}, x{rs1}, {imm}", "I", rd, rs1, immediate=imm) if name else unknown
    if op == 0x03:
        name = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}.get(f3)
        return DecodedInstruction(f"{name} x{rd}, {imm_i}(x{rs1})", "I", rd, rs1, immediate=imm_i) if name else unknown
    if op == 0x23:
        name = {0: "sb", 1: "sh", 2: "sw"}.get(f3)
        imm = signed(((word >> 25) << 5) | ((word >> 7) & 31), 12)
        return DecodedInstruction(f"{name} x{rs2}, {imm}(x{rs1})", "S", rs1=rs1, rs2=rs2, immediate=imm) if name else unknown
    if op == 0x63:
        name = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}.get(f3)
        imm = signed(((word >> 31) << 12) | (((word >> 7) & 1) << 11)
                     | (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1), 13)
        target = (pc + imm) & 0xFFFFFFFF
        return DecodedInstruction(f"{name} x{rs1}, x{rs2}, 0x{target:08X}", "B", rs1=rs1, rs2=rs2, immediate=imm, target=target) if name else unknown
    if op in (0x37, 0x17):
        name = "lui" if op == 0x37 else "auipc"
        return DecodedInstruction(f"{name} x{rd}, 0x{word >> 12:05X}", "U", rd, immediate=signed(word & 0xFFFFF000))
    if op == 0x6F:
        imm = signed(((word >> 31) << 20) | (((word >> 12) & 255) << 12)
                     | (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1), 21)
        target = (pc + imm) & 0xFFFFFFFF
        return DecodedInstruction(f"jal x{rd}, 0x{target:08X}", "J", rd, immediate=imm, target=target)
    if op == 0x67 and f3 == 0:
        return DecodedInstruction(f"jalr x{rd}, {imm_i}(x{rs1})", "I", rd, rs1, immediate=imm_i)
    if word in (0x00000073, 0x00100073):
        return DecodedInstruction("ecall" if word == 0x73 else "ebreak", "I")
    if op == 0x0F and f3 == 0 and (word >> 28) == 0:
        def fence_set(mask):
            return "".join(name for bit, name in ((8, "i"), (4, "o"), (2, "r"), (1, "w")) if mask & bit) or "0"
        return DecodedInstruction(f"fence {fence_set((word >> 24) & 15)}, {fence_set((word >> 20) & 15)}", "I")
    return unknown



# =============================================================================
# Interfaz de escritorio · Tkinter / ttk
# =============================================================================

LIGHT_THEME = {
    "bg": "#EEF2F7",
    "panel": "#FFFFFF",
    "input": "#F4F7FB",
    "fg": "#17283F",
    "muted": "#52657D",
    "line": "#CED8E6",
    "accent": "#087B61",
    "accent_fg": "#FFFFFF",
    "select": "#CEDEF5",
    "row": "#F3F6FA",
    "changed": "#FFF0CB",
    "warn": "#865300",
    "error": "#AE2437",
    "pc": "#D8F0E8",
    "blue": "#255DA4",
}


class Tooltip:
    def __init__(self, widget, text):
        self.widget, self.text, self.tip, self.timer = widget, text, None, None
        widget.bind("<Enter>", self.schedule, add=True)
        widget.bind("<Leave>", self.hide, add=True)
        widget.bind("<ButtonPress>", self.hide, add=True)
        widget.bind("<Destroy>", self.hide, add=True)

    def schedule(self, _event=None):
        self.hide()
        self.timer = self.widget.after(550, self.show)

    def show(self):
        self.timer = None
        if not self.widget.winfo_exists():
            return
        self.tip = tk.Toplevel(self.widget)
        self.tip.wm_overrideredirect(True)
        ttk.Label(self.tip, text=self.text, padding=10, wraplength=340,
                  style="Card.TLabel").pack()
        self.tip.update_idletasks()
        x = min(self.widget.winfo_rootx(), self.widget.winfo_screenwidth() - self.tip.winfo_reqwidth() - 12)
        y = min(self.widget.winfo_rooty() + self.widget.winfo_height() + 6,
                self.widget.winfo_screenheight() - self.tip.winfo_reqheight() - 12)
        self.tip.geometry(f"+{max(0, x)}+{max(0, y)}")

    def hide(self, _event=None):
        if self.timer:
            self.widget.after_cancel(self.timer)
            self.timer = None
        if self.tip:
            self.tip.destroy()
            self.tip = None


class RV32IDebuggerGUI(tk.Tk):
    ABI_NAMES = ABI_NAMES

    def __init__(self):
        super().__init__()
        self.title("RV32I Debugger | Nexys 3")
        self.geometry("1260x860")
        self.minsize(1060, 760)
        self.dev: Optional[RV32IDebugger] = None
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="rv32i-uart")
        self.result_queue = queue.Queue()
        self.progress_queue = queue.Queue()
        self.cancel_event = Event()
        self.busy = False
        self.closing = False
        self.close_started = False
        self._destroyed = False
        self.faulted = False
        self.snapshot_value = None
        self.register_values = None
        self.changed_registers = set()
        self.imem_values = {}
        self.imem_source = "Sin lectura"
        self.imem_is_preview = False
        self.history = deque(maxlen=200)
        self.history_count = 0
        self.device_widgets = []
        self.classic_widgets = []
        self.console_visible = True
        self._compact_mode = False
        self._init_vars()
        self._configure_style()
        self._build_ui()
        self._bind_keys()
        self._apply_colors()
        self.refresh_ports()
        self._sync_controls()
        self._poll_id = self.after(40, self._poll_async_results)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.bind("<Configure>", self._on_resize, add=True)
        self.log("Listo. Selecciona el puerto de la Nexys 3 y conecta la FPGA.", "info")

    def _init_vars(self):
        defaults = {"port": "", "baud": "57600", "status": "Listo para conectar",
                    "connection": "SIN CONEXIÓN", "sample": "Sin captura",
                    "pc": "0x--------", "out": "0x--------", "instr": "0x--------",
                    "last_pc": "0x--------", "last_out": "0x--------", "last_instr": "0x--------",
                    "decoded": "Esperando una instrucción", "decode_detail": "Conecta la placa para leer el estado.",
                    "last_decoded": "Sin captura de ejecución", "filter": "", "reg_count": "32 registros",
                    "imem_addr": "0x00000000", "imem_data": "0x00000013", "hex_path": "",
                    "hex_base": "", "program": "Ningún archivo seleccionado",
                    "memory_caption": "Sin lectura · 0 palabras · 0 bytes", "progress": "",
                    "step_count": "0 capturas", "dump_words": "256"}
        for name, value in defaults.items():
            setattr(self, f"{name}_var", tk.StringVar(self, value=value))
        self.verify_var = tk.BooleanVar(self, value=True)
        self.only_changed_var = tk.BooleanVar(self, value=False)
        self.filter_var.trace_add("write", lambda *_: self._render_registers())

    def _configure_style(self):
        fonts = {f.lower(): f for f in tkfont.families(self)}
        self.sans = next((fonts[f.lower()] for f in ("Segoe UI", "Noto Sans", "DejaVu Sans", "Helvetica", "Arial") if f.lower() in fonts), "sans-serif")
        self.mono = next((fonts[f.lower()] for f in ("Cascadia Code", "Consolas", "DejaVu Sans Mono", "Courier") if f.lower() in fonts), "monospace")
        tkfont.nametofont("TkDefaultFont").configure(family=self.sans, size=10)
        tkfont.nametofont("TkTextFont").configure(family=self.sans, size=10)
        self.style = ttk.Style(self)
        self.style.theme_use("clam")

    def _apply_colors(self):
        c = self.colors = LIGHT_THEME
        self.configure(bg=c["bg"])
        s = self.style
        s.configure(".", font=(self.sans, 10), background=c["bg"], foreground=c["fg"],
                    bordercolor=c["line"], lightcolor=c["line"], darkcolor=c["line"], focuscolor=c["accent"])
        s.configure("TFrame", background=c["bg"])
        s.configure("Card.TFrame", background=c["panel"])
        s.configure("TLabel", background=c["bg"], foreground=c["fg"])
        s.configure("Muted.TLabel", foreground=c["muted"])
        s.configure("Title.TLabel", font=(self.sans, 22, "bold"))
        s.configure("Brand.TLabel", background=c["accent"], foreground=c["accent_fg"], font=(self.mono, 16, "bold"), padding=(10, 9))
        s.configure("Badge.TLabel", background=c["panel"], foreground=c["muted"], padding=(12, 8), font=(self.sans, 9, "bold"))
        s.configure("Card.TLabel", background=c["panel"])
        s.configure("CardMuted.TLabel", background=c["panel"], foreground=c["muted"], font=(self.sans, 9))
        s.configure("CardTitle.TLabel", background=c["panel"], font=(self.sans, 10, "bold"))
        s.configure("Metric.TLabel", background=c["panel"], foreground=c["accent"], font=(self.mono, 22, "bold"))
        s.configure("Assembly.TLabel", background=c["panel"], foreground=c["blue"], font=(self.mono, 14, "bold"))
        s.configure("Mono.TLabel", background=c["panel"], font=(self.mono, 10))
        s.configure("TButton", background=c["panel"], foreground=c["fg"], padding=(11, 8), relief="flat", borderwidth=1)
        s.map("TButton", background=[("disabled", c["bg"]), ("pressed", c["select"]), ("active", c["row"])],
              foreground=[("disabled", c["muted"])], bordercolor=[("focus", c["accent"])])
        s.configure("Primary.TButton", background=c["accent"], foreground=c["accent_fg"], font=(self.sans, 10, "bold"))
        s.map("Primary.TButton", background=[("disabled", c["panel"]), ("active", c["accent"]), ("pressed", c["select"])],
              foreground=[("disabled", c["muted"]), ("pressed", c["fg"]), ("!disabled", c["accent_fg"])])
        s.configure("Stop.TButton", foreground=c["error"])
        s.configure("Small.TButton", padding=(8, 4), font=(self.sans, 9))
        s.configure("TEntry", fieldbackground=c["input"], insertcolor=c["fg"], padding=7)
        s.map("TEntry", fieldbackground=[("disabled", c["panel"])], foreground=[("disabled", c["muted"])])
        s.configure("TCombobox", fieldbackground=c["input"], background=c["panel"], arrowcolor=c["fg"], padding=6)
        s.map("TCombobox", fieldbackground=[("readonly", c["input"]), ("disabled", c["panel"])],
              foreground=[("disabled", c["muted"]), ("readonly", c["fg"])], selectbackground=[("readonly", c["input"])], selectforeground=[("readonly", c["fg"])])
        self.option_add("*TCombobox*Listbox.background", c["input"])
        self.option_add("*TCombobox*Listbox.foreground", c["fg"])
        self.option_add("*TCombobox*Listbox.selectBackground", c["select"])
        s.configure("TCheckbutton", background=c["bg"], foreground=c["fg"], padding=4)
        s.map("TCheckbutton", background=[("active", c["bg"])], indicatorbackground=[("selected", c["accent"]), ("!selected", c["input"])])
        s.configure("Card.TCheckbutton", background=c["panel"])
        s.map("Card.TCheckbutton", background=[("active", c["panel"])])
        s.configure("TNotebook", background=c["bg"], borderwidth=0, tabmargins=(0, 0, 0, 10))
        s.configure("TNotebook.Tab", background=c["bg"], foreground=c["muted"], padding=(20, 10), font=(self.sans, 10, "bold"))
        s.map("TNotebook.Tab", background=[("selected", c["panel"])], foreground=[("selected", c["accent"]), ("active", c["fg"])])
        s.configure("Treeview", background=c["panel"], fieldbackground=c["panel"], foreground=c["fg"],
                    font=(self.mono, 10), rowheight=28, borderwidth=0)
        s.configure("Treeview.Heading", background=c["row"], foreground=c["muted"], font=(self.sans, 9, "bold"), padding=(8, 9), relief="flat")
        s.map("Treeview", background=[("selected", c["select"])], foreground=[("selected", c["fg"])])
        s.map("Treeview.Heading", background=[("active", c["line"])])
        s.configure("Vertical.TScrollbar", background=c["line"], troughcolor=c["panel"], arrowcolor=c["muted"], borderwidth=0)
        s.configure("Horizontal.TScrollbar", background=c["line"], troughcolor=c["panel"], arrowcolor=c["muted"], borderwidth=0)
        s.configure("Horizontal.TProgressbar", background=c["accent"], troughcolor=c["panel"], borderwidth=0)
        for widget in self.classic_widgets:
            widget.configure(bg=c["input"], fg=c["fg"], insertbackground=c["accent"], selectbackground=c["select"])
        for tree in (self.reg_tree, self.imem_tree, self.trace_tree):
            tree.tag_configure("odd", background=c["row"])
            tree.tag_configure("even", background=c["panel"])
            tree.tag_configure("changed", background=c["changed"], foreground=c["warn"])
            tree.tag_configure("pc", background=c["pc"], foreground=c["accent"])
            tree.tag_configure("last", foreground=c["blue"])
        for level, color in (("info", c["muted"]), ("ok", c["accent"]), ("warning", c["warn"]), ("error", c["error"])):
            self.log_text.tag_configure(level, foreground=color)
        self._sync_controls()

    def _button(self, parent, text, command, style="TButton", rule=None, tip=None):
        button = ttk.Button(parent, text=text, command=command, style=style, cursor="hand2")
        if rule:
            self.device_widgets.append((button, rule))
        if tip:
            Tooltip(button, tip)
        return button

    def _card(self, parent):
        return ttk.Frame(parent, style="Card.TFrame", padding=16)

    def _build_ui(self):
        self.columnconfigure(0, weight=1)
        self.rowconfigure(3, weight=1)
        header = ttk.Frame(self, padding=(20, 15, 20, 12))
        header.grid(row=0, column=0, sticky="ew")
        ttk.Label(header, text="RV", style="Brand.TLabel").pack(side="left", padx=(0, 14))
        title = ttk.Frame(header)
        title.pack(side="left")
        ttk.Label(title, text="RV32I Debugger", style="Title.TLabel").pack(anchor="w")
        ttk.Label(title, text="NEXYS 3  /  SPARTAN-6   ·   MONOCICLO", style="Muted.TLabel", font=(self.sans, 9)).pack(anchor="w")
        self.state_badge = ttk.Label(header, textvariable=self.connection_var, style="Badge.TLabel")
        self.state_badge.pack(side="right")

        connection = ttk.Frame(self, padding=12, style="Card.TFrame")
        connection.grid(row=1, column=0, padx=20, pady=(0, 10), sticky="ew")
        ttk.Label(connection, text="CONEXIÓN", style="CardTitle.TLabel").pack(side="left", padx=(0, 16))
        self.port_combo = ttk.Combobox(connection, textvariable=self.port_var, width=17)
        self.port_combo.pack(side="left", padx=(0, 6))
        Tooltip(self.port_combo, "Selecciona o escribe el puerto: COM3, /dev/ttyUSB0…")
        self.ports_button = self._button(connection, "Buscar puertos", self.refresh_ports)
        self.ports_button.pack(side="left", padx=(0, 18))
        ttk.Label(connection, text="Baudios", style="CardMuted.TLabel").pack(side="left", padx=(0, 6))
        self.baud_combo = ttk.Combobox(connection, textvariable=self.baud_var, width=8, state="readonly", values=(9600, 19200, 38400, 57600, 115200, 230400, 460800))
        self.baud_combo.pack(side="left", padx=(0, 12))
        Tooltip(self.baud_combo, "Debe coincidir con BAUD_RATE de cpu.v. Valor actual: 57600, 8N1.")
        self.connect_button = self._button(connection, "Conectar", self.toggle_connection, "Primary.TButton",
                                            tip="Comprueba PING y detiene la CPU con HALT al conectar.")
        self.connect_button.pack(side="left")
        self._button(connection, "Ayuda", self.show_help).pack(side="right")

        toolbar = ttk.Frame(self)
        toolbar.grid(row=2, column=0, padx=20, pady=(0, 12), sticky="ew")
        for text, command, style, rule, tip in [
            ("Paso · F10", self.do_step, "Primary.TButton", "paused", "Ejecuta una instrucción y actualiza CPU y registros."),
            ("Ejecutar · F5", self.do_run, "TButton", "paused", "Activa RUN. Los valores mostrados quedan como última captura."),
            ("Detener · F6", self.do_halt, "Stop.TButton", "device", "Envía HALT y lee una captura coherente."),
            ("Reiniciar", self.do_reset, "TButton", "device", "Ctrl+R. Reinicia el PC; el banco de registros del RTL conserva sus valores."),
            ("Actualizar", self.refresh_cpu_state, "TButton", "paused", "Actualiza CPU y registros mientras está detenido."),
        ]:
            self._button(toolbar, text, command, style, rule, tip).pack(side="left", padx=(0, 7))
        self._button(toolbar, "PING", self.do_ping, rule="device", tip="Comprueba la identificador RV32 y versión 1.0 de la placa.").pack(side="right")
        ttk.Label(toolbar, textvariable=self.sample_var, style="Muted.TLabel", font=(self.sans, 9)).pack(side="right", padx=12)

        self.notebook = ttk.Notebook(self)
        self.notebook.grid(row=3, column=0, padx=20, sticky="nsew")
        self.cpu_tab, self.reg_tab, self.imem_tab = (ttk.Frame(self.notebook) for _ in range(3))
        self.notebook.add(self.cpu_tab, text="01   CPU")
        self.notebook.add(self.reg_tab, text="02   Registros")
        self.notebook.add(self.imem_tab, text="03   Memoria y programa")
        self._build_cpu_tab()
        self._build_register_tab()
        self._build_imem_tab()
        self._build_wishbone_tab()
        self._build_console()

        footer = ttk.Frame(self, padding=(20, 8))
        footer.grid(row=5, column=0, sticky="ew")
        self.status_label = ttk.Label(footer, textvariable=self.status_var, style="Muted.TLabel", font=(self.sans, 9))
        self.status_label.pack(side="left")
        self.progress_bar = ttk.Progressbar(footer, length=130, mode="determinate")
        self.progress_bar.pack(side="right", padx=(10, 0))
        ttk.Label(footer, textvariable=self.progress_var, style="Muted.TLabel", font=(self.sans, 9)).pack(side="right")

    def _build_cpu_tab(self):
        self.cpu_tab.columnconfigure(0, weight=1)
        self.cpu_tab.rowconfigure(2, weight=1)
        metrics = ttk.Frame(self.cpu_tab)
        metrics.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        for i, (caption, variable, note) in enumerate([
            ("PROGRAM COUNTER", self.pc_var, "Dirección de la instrucción actual"),
            ("WRITE BACK · OUT", self.out_var, "Dato combinacional del ciclo actual"),
            ("INSTRUCCIÓN · 32 BITS", self.instr_var, "Palabra leída en el PC actual"),
        ]):
            metrics.columnconfigure(i, weight=1, uniform="metrics")
            card = self._card(metrics)
            card.grid(row=0, column=i, sticky="nsew", padx=(0 if i == 0 else 5, 0 if i == 2 else 5))
            ttk.Label(card, text=caption, style="CardMuted.TLabel").pack(anchor="w")
            value = ttk.Label(card, textvariable=variable, style="Metric.TLabel", cursor="hand2")
            value.pack(anchor="w", pady=(8, 6))
            value.bind("<Button-1>", lambda _e, v=variable: self._copy(v.get()))
            Tooltip(value, "Clic para copiar el valor hexadecimal.")
            ttk.Label(card, text=note, style="CardMuted.TLabel").pack(anchor="w")

        details = ttk.Frame(self.cpu_tab)
        details.grid(row=1, column=0, sticky="ew", pady=(0, 10))
        details.columnconfigure(0, weight=6, uniform="details")
        details.columnconfigure(1, weight=5, uniform="details")
        current = self._card(details)
        current.grid(row=0, column=0, sticky="nsew", padx=(0, 5))
        ttk.Label(current, text="INSTRUCCIÓN ACTUAL", style="CardTitle.TLabel").pack(anchor="w")
        ttk.Label(current, textvariable=self.decoded_var, style="Assembly.TLabel").pack(anchor="w", pady=(10, 6))
        self.decode_label = ttk.Label(current, textvariable=self.decode_detail_var, style="CardMuted.TLabel", wraplength=520)
        self.decode_label.pack(anchor="w")
        current.bind("<Configure>", lambda e: self.decode_label.configure(wraplength=max(150, e.width - 35)))
        last = self._card(details)
        last.grid(row=0, column=1, sticky="nsew", padx=(5, 0))
        last_header = ttk.Frame(last, style="Card.TFrame")
        last_header.pack(fill="x")
        ttk.Label(last_header, text="ÚLTIMA CAPTURA", style="CardTitle.TLabel").pack(side="left")
        ttk.Label(last_header, textvariable=self.last_instr_var, style="Mono.TLabel").pack(side="right")
        ttk.Label(last, textvariable=self.last_decoded_var, style="Assembly.TLabel").pack(anchor="w", pady=(10, 6))
        line = ttk.Frame(last, style="Card.TFrame")
        line.pack(fill="x")
        for caption, variable in (("PC", self.last_pc_var), ("OUT", self.last_out_var)):
            ttk.Label(line, text=caption, style="CardMuted.TLabel").pack(side="left", padx=(0, 6))
            ttk.Label(line, textvariable=variable, style="Mono.TLabel").pack(side="left", padx=(0, 16))

        history = ttk.Frame(self.cpu_tab)
        history.grid(row=2, column=0, sticky="nsew")
        history.columnconfigure(0, weight=1)
        history.rowconfigure(1, weight=1)
        bar = ttk.Frame(history)
        bar.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        ttk.Label(bar, text="Historial de pasos", font=(self.sans, 10, "bold")).pack(side="left")
        ttk.Label(bar, text="  ·  STEP y fin de RUN", style="Muted.TLabel", font=(self.sans, 9)).pack(side="left")
        self._button(bar, "Limpiar", self.clear_history, "Small.TButton").pack(side="right")
        self._button(
            bar,
            "Guardar historial",
            self.save_history_log,
            "Small.TButton",
            tip="Guarda las capturas STEP y HALT/RUN en un archivo .log."
        ).pack(side="right", padx=(0, 6))
        ttk.Label(bar, textvariable=self.step_count_var, style="Muted.TLabel").pack(side="right", padx=12)
        self.trace_tree = self._table(history, [("n", "#", 50), ("event", "Acción", 85), ("pc", "PC ejecutado", 145),
                                    ("instr", "Instrucción", 145), ("asm", "Ensamblador", 350), ("wb", "OUT capturado", 145)], row=1, height=4)

    def _table(self, parent, columns, row, height=8):
        frame = ttk.Frame(parent)
        frame.grid(row=row, column=0, sticky="nsew")
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(0, weight=1)
        tree = ttk.Treeview(frame, columns=[x[0] for x in columns], show="headings", height=height, selectmode="browse")
        for name, caption, width in columns:
            tree.heading(name, text=caption, anchor="w")
            tree.column(name, width=width, minwidth=min(width, 90), anchor="w", stretch=name not in ("n", "reg", "abi", "mark"))
        tree.grid(row=0, column=0, sticky="nsew")
        vertical = ttk.Scrollbar(frame, command=tree.yview)
        vertical.grid(row=0, column=1, sticky="ns")
        horizontal = ttk.Scrollbar(frame, orient="horizontal", command=tree.xview)
        horizontal.grid(row=1, column=0, sticky="ew")
        tree.configure(yscrollcommand=vertical.set, xscrollcommand=horizontal.set)
        tree.bind("<Control-c>", lambda _e: self._copy_table_row(tree))
        Tooltip(tree, "Selecciona una fila y presiona Ctrl+C para copiarla.")
        return tree

    def _build_register_tab(self):
        self.reg_tab.columnconfigure(0, weight=1)
        self.reg_tab.rowconfigure(1, weight=1)
        bar = ttk.Frame(self.reg_tab)
        bar.grid(row=0, column=0, sticky="ew", pady=(0, 12))
        ttk.Label(bar, text="Buscar registro", style="Muted.TLabel").pack(side="left", padx=(0, 8))
        ttk.Entry(bar, textvariable=self.filter_var, width=19).pack(side="left", padx=(0, 12))
        ttk.Checkbutton(bar, text="Solo cambios", variable=self.only_changed_var, command=self._render_registers).pack(side="left")
        self._button(bar, "Leer x0–x31", self.refresh_registers, rule="paused").pack(side="right")
        self._button(bar, "Exportar CSV", self.export_registers).pack(side="right", padx=8)
        ttk.Label(bar, textvariable=self.reg_count_var, style="Muted.TLabel").pack(side="right", padx=12)
        self.reg_tree = self._table(self.reg_tab, [("reg", "Registro", 95), ("abi", "ABI", 105), ("hex", "Hexadecimal", 190),
                                 ("unsigned", "Decimal sin signo", 200), ("signed", "Decimal con signo", 200), ("change", "Comparación", 180)], row=1, height=14)
        ttk.Label(self.reg_tab, text="Ámbar: cambió desde la lectura anterior.  ·  x0 siempre es cero.  ·  Los registros se actualizan al dar un paso.",
                  style="Muted.TLabel", font=(self.sans, 9)).grid(row=2, column=0, sticky="w", pady=(8, 2))
        self._render_registers()

    def _build_imem_tab(self):
        self.imem_tab.columnconfigure(0, weight=1)
        self.imem_tab.rowconfigure(3, weight=1)
        loader = self._card(self.imem_tab)
        loader.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        loader.columnconfigure(1, weight=1)
        ttk.Label(loader, text="PROGRAMA .HEX", style="CardTitle.TLabel").grid(row=0, column=0, padx=(0, 12))
        self.path_entry = ttk.Entry(loader, textvariable=self.hex_path_var)
        self.path_entry.grid(row=0, column=1, sticky="ew", padx=(0, 8))
        self.browse_button = self._button(loader, "Abrir…", self.browse_hex)
        self.browse_button.grid(row=0, column=2, padx=(0, 8))
        self.preview_button = self._button(loader, "Previsualizar", self.preview_hex)
        self.preview_button.grid(row=0, column=3)
        options = ttk.Frame(loader, style="Card.TFrame")
        options.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(10, 0))
        ttk.Label(options, text="Base", style="CardMuted.TLabel").pack(side="left", padx=(0, 8))
        self.base_entry = ttk.Entry(options, textvariable=self.hex_base_var, width=12)
        self.base_entry.pack(side="left", padx=(0, 7))
        Tooltip(self.base_entry, "Vacío: respeta la dirección @ del archivo. O escribe una base decimal o 0x hexadecimal.")
        ttk.Label(options, text="Vacío = auto", style="CardMuted.TLabel").pack(side="left", padx=(0, 16))
        self.verify_check = ttk.Checkbutton(options, text="Verificar escritura", variable=self.verify_var, style="Card.TCheckbutton")
        self.verify_check.pack(side="left")
        self._button(loader, "Cargar a FPGA", self.load_hex, "Primary.TButton", "paused",
                     "Programa IMEM, verifica si está marcado y reinicia el PC. Solo se reemplaza el rango cargado.").grid(row=1, column=3, pady=(10, 0))
        self.program_label = ttk.Label(loader, textvariable=self.program_var, style="CardMuted.TLabel", wraplength=1050)
        self.program_label.grid(row=2, column=0, columnspan=4, sticky="w", pady=(8, 0))
        loader.bind("<Configure>", lambda e: self.program_label.configure(wraplength=max(100, e.width - 40)))

        manual = ttk.Frame(self.imem_tab)
        manual.grid(row=1, column=0, sticky="ew", pady=(0, 10))
        ttk.Label(manual, text="Dirección", style="Muted.TLabel").pack(side="left", padx=(0, 7))
        self.addr_entry = ttk.Entry(manual, textvariable=self.imem_addr_var, width=13)
        self.addr_entry.pack(side="left", padx=(0, 15))
        ttk.Label(manual, text="Palabra", style="Muted.TLabel").pack(side="left", padx=(0, 7))
        self.data_entry = ttk.Entry(manual, textvariable=self.imem_data_var, width=13)
        self.data_entry.pack(side="left", padx=(0, 10))
        self._button(manual, "Leer", self.read_imem_manual, rule="paused").pack(side="left", padx=(0, 7))
        self._button(manual, "Escribir y verificar", self.write_imem_manual, rule="paused").pack(side="left")
        self._button(manual, "Exportar HEX", self.export_imem).pack(side="right")
        memory_bar = ttk.Frame(self.imem_tab)
        memory_bar.grid(row=2, column=0, sticky="ew", pady=(0, 7))
        ttk.Label(memory_bar, textvariable=self.memory_caption_var, style="Muted.TLabel").pack(side="left")
        self._button(memory_bar, "Leer bloque IMEM", self.dump_imem, rule="paused", style="Small.TButton").pack(side="right")
        self.dump_words_entry = ttk.Entry(memory_bar, textvariable=self.dump_words_var, width=8)
        self.dump_words_entry.pack(side="right", padx=(6, 8))
        ttk.Label(memory_bar, text="Palabras", style="Muted.TLabel").pack(side="right")
        Tooltip(self.dump_words_entry, "Cantidad de palabras de 32 bits a leer desde la dirección indicada arriba.")
        self.imem_tree = self._table(self.imem_tab, [("n", "#", 55), ("mark", "Estado", 75), ("addr", "Dirección", 145), ("word", "Palabra de 32 bits", 165),
                                    ("bytes", "Bytes · little-endian", 205), ("asm", "Ensamblador RV32I", 360)], row=3, height=8)
        self.imem_tree.bind("<<TreeviewSelect>>", self._select_imem)
        ttk.Label(self.imem_tab, text="IMEM: direcciones de 32 bits alineadas a 4 bytes. La capacidad física real depende del RTL sintetizado. HEX: bytes (93 00 50 00) o palabras de 32 bits (00500093); no Intel HEX.",
                  style="Muted.TLabel", font=(self.sans, 9)).grid(row=4, column=0, sticky="w", pady=(7, 2))

    def _build_wishbone_tab(self):
        self.wb_tab = ttk.Frame(self.notebook, padding=16)
        self.notebook.add(self.wb_tab, text="04   Wishbone / DMEM")
        self.wb_addr_var = tk.StringVar(value="0x00010000")
        self.wb_data_var = tk.StringVar(value="0x00000000")
        self.wb_sel_var = tk.StringVar(value="0xF")
        self.wb_result_var = tk.StringVar(value="Sin acceso")
        self.wb_entries = []
        form = self._card(self.wb_tab)
        form.pack(fill="x")
        for row, (label, variable) in enumerate((("ADR()", self.wb_addr_var),
                                                 ("DAT()", self.wb_data_var),
                                                 ("SEL()", self.wb_sel_var))):
            ttk.Label(form, text=label, style="CardMuted.TLabel").grid(row=row, column=0, sticky="w", padx=(0, 12), pady=6)
            entry = ttk.Entry(form, textvariable=variable, width=24)
            entry.grid(row=row, column=1, sticky="w", pady=6)
            self.wb_entries.append(entry)
        buttons = ttk.Frame(form, style="Card.TFrame")
        buttons.grid(row=3, column=0, columnspan=2, sticky="w", pady=12)
        self._button(buttons, "READ", lambda: self._wb_access(False), rule="device").pack(side="left", padx=(0, 8))
        self._button(buttons, "WRITE", lambda: self._wb_access(True), rule="device").pack(side="left")
        ttk.Label(form, textvariable=self.wb_result_var, style="CardTitle.TLabel").grid(row=4, column=0, columnspan=2, sticky="w")
        ttk.Label(self.wb_tab, text=(
            "IMEM: 0x00000000 · DMEM: 0x00010000 · Loader: 0x10000000 · Debug: 0x10001000\n"
            "Memorias: CPU detenida; ADR alineada a 4 bytes; SEL elige los bytes.\n"
            "Registros de control: SEL = 0xF. Cada botón realiza un único acceso."
        ), style="Muted.TLabel").pack(anchor="w", pady=16)

    def _wb_access(self, write):
        dev = self._require_device()
        if dev is None:
            return
        try:
            address = self._parse_int(self.wb_addr_var.get())
            data = self._parse_int(self.wb_data_var.get()) if write else 0
            sel = self._parse_int(self.wb_sel_var.get())
            if address < 0 or address > 0xFFFFFFFC or address & 3:
                raise ValueError("ADR debe estar alineada a 4 bytes y caber en 32 bits.")
            if not 0 <= data <= 0xFFFFFFFF or not 1 <= sel <= 15:
                raise ValueError("DAT o SEL fuera de rango.")
        except ValueError as exc:
            self._handle_error(exc, False)
            return
        def job():
            value = dev.write(address, data, sel) if write else dev.read(address, sel)
            dev.read_status()
            return value
        def success(value):
            result = "ACK" if write else f"ACK · DAT() = 0x{value:08X}"
            self.wb_result_var.set(result)
            if not write:
                self.wb_data_var.set(f"0x{value:08X}")
            self.sample_var.set("Acceso Wishbone · actualizar CPU para una nueva captura")
            self.log(f"{'WRITE' if write else 'READ'} ADR=0x{address:08X}, SEL=0x{sel:X}: {result}", "ok")
        self._submit(job, success, "Accediendo a Wishbone…")

    def _build_console(self):
        self.console = ttk.Frame(self)
        self.console.grid(row=4, column=0, padx=20, pady=(12, 0), sticky="ew")
        self.console.columnconfigure(0, weight=1)
        bar = ttk.Frame(self.console)
        bar.grid(row=0, column=0, sticky="ew", pady=(0, 5))
        ttk.Label(bar, text="CONSOLA", style="Muted.TLabel", font=(self.sans, 9, "bold")).pack(side="left")
        self.console_button = self._button(bar, "Ocultar", self.toggle_console, "Small.TButton")
        self.console_button.pack(side="right")
        self._button(bar, "Limpiar", self.clear_log, "Small.TButton").pack(side="right", padx=6)
        self._button(bar, "Guardar log", self.save_log, "Small.TButton").pack(side="right")
        self.console_body = ttk.Frame(self.console)
        self.console_body.grid(row=1, column=0, sticky="ew")
        self.console_body.columnconfigure(0, weight=1)
        self.log_text = tk.Text(self.console_body, height=4, wrap="word", state="disabled", font=(self.mono, 9),
                                borderwidth=0, highlightthickness=0, padx=10, pady=8)
        self.log_text.grid(row=0, column=0, sticky="ew")
        self.classic_widgets.append(self.log_text)
        scroll = ttk.Scrollbar(self.console_body, command=self.log_text.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.log_text.configure(yscrollcommand=scroll.set)
    # Todas las llamadas a Tk ocurren en el hilo principal. El trabajador UART
    # único devuelve datos por colas y nunca toca widgets ni StringVar.
    def _bind_keys(self):
        for sequence, callback in (("<F5>", self.do_run), ("<F6>", self.do_halt), ("<F10>", self.do_step),
                                   ("<Control-r>", self.do_reset), ("<Control-o>", self.browse_hex),
                                   ("<Control-l>", self.clear_log)):
            self.bind(sequence, lambda _e, fn=callback: (fn(), "break")[1])
        for index in range(3):
            self.bind(f"<Control-Key-{index + 1}>", lambda _e, i=index: self.notebook.select(i))

    def toggle_console(self):
        self.console_visible = not self.console_visible
        if self.console_visible:
            self.console_body.grid()
        else:
            self.console_body.grid_remove()
        self.console_button.configure(text="Ocultar" if self.console_visible else "Mostrar")

    def _on_resize(self, event):
        if event.widget is not self or self.closing:
            return
        compact = event.height < 820
        if compact != self._compact_mode:
            self._compact_mode = compact
            if compact and self.console_visible:
                self.toggle_console()
            elif not compact and not self.console_visible:
                self.toggle_console()

    def log(self, message, level="info"):
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"{time.strftime('%H:%M:%S')}  {message}\n", level)
        lines = int(self.log_text.index("end-1c").split(".")[0])
        if lines > 1000:
            self.log_text.delete("1.0", f"{lines - 1000 + 1}.0")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def clear_log(self):
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    def _copy(self, text):
        self.clipboard_clear()
        self.clipboard_append(text)
        self.log("Copiado al portapapeles.", "ok")

    def _copy_table_row(self, tree):
        selection = tree.selection()
        if selection:
            self._copy("\t".join(str(x) for x in tree.item(selection[0], "values")))
        return "break"

    @staticmethod
    def _parse_int(text):
        text = text.strip()
        if not text:
            raise ValueError("El campo está vacío.")
        try:
            return int(text, 0) if text.lower().lstrip("+-").startswith(("0x", "0b", "0o")) else int(text, 10)
        except ValueError as exc:
            raise ValueError(f"Valor inválido: '{text}'. Usa decimal o el prefijo 0x para hexadecimal.") from exc

    _to_signed32 = staticmethod(signed)

    def _sync_controls(self):
        connected = self.dev is not None and self.dev.connected
        running = connected and self.dev.running
        ready = connected and not self.busy and not self.closing and not self.faulted
        for widget, rule in self.device_widgets:
            allowed = ready and (rule == "device" or not running)
            widget.state(["!disabled"] if allowed else ["disabled"])
        idle = not self.busy and not self.closing
        self.connect_button.state(["!disabled"] if idle else ["disabled"])
        self.connect_button.configure(text="Desconectar" if connected else "Conectar")
        self.port_combo.configure(state="normal" if idle and not connected else "disabled")
        self.baud_combo.configure(state="readonly" if idle and not connected else "disabled")
        self.ports_button.state(["!disabled"] if idle and not connected else ["disabled"])
        for widget in (self.path_entry, self.base_entry, self.browse_button, self.preview_button,
                       self.verify_check, self.addr_entry, self.data_entry, self.dump_words_entry):
            widget.state(["!disabled"] if idle else ["disabled"])
        for widget in self.wb_entries:
            widget.state(["!disabled"] if idle else ["disabled"])
        if self.closing:
            self.status_var.set("Terminando la operación y cerrando el puerto…")
        elif self.busy:
            self.status_var.set(self._activity)
        elif self.faulted:
            self.status_var.set("Error de comunicación. Desconecta y comprueba la placa antes de reconectar.")
        elif connected:
            if running:
                self.status_var.set("CPU en RUN · Detener (F6) captura CPU y registros.")
            else:
                self.status_var.set("CPU detenida · F10: paso   F5: ejecutar   Ctrl+R: reiniciar")
        else:
            self.status_var.set("Selecciona el puerto UART de la Nexys 3.")
        state = "SIN CONEXIÓN"
        if connected:
            state = f"{self.dev.port} · UART" + ("  /  RUN" if running else "  /  HALT")
        if self.faulted:
            state = "COMUNICACIÓN SIN CONFIRMAR"
        self.connection_var.set(state)
        if hasattr(self, "colors"):
            self.state_badge.configure(foreground=self.colors["warn" if self.faulted else "accent" if connected else "muted"])

    def _require_device(self, paused=False):
        if self.busy or self.closing:
            return None
        if self.faulted:
            self.log("La comunicación necesita reconexión.", "warning")
            return None
        if self.dev is None or not self.dev.connected:
            self.log("Conecta la FPGA para continuar.", "warning")
            return None
        if paused and self.dev.running:
            self.log("Detén la CPU con F6 para leer un estado coherente.", "warning")
            return None
        return self.dev

    def _submit(self, job, on_success=None, status="Trabajando…"):
        if self.busy or self.closing:
            return False
        self.busy = True
        self._activity = status
        self.cancel_event.clear()
        self.progress_var.set("")
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.start(15)
        self._sync_controls()
        future = self.executor.submit(job)
        future.add_done_callback(lambda f: self.result_queue.put((f, on_success)))
        return True

    def _poll_async_results(self):
        try:
            while True:
                done, total, label = self.progress_queue.get_nowait()
                self.progress_bar.stop()
                self.progress_bar.configure(mode="determinate", maximum=max(1, total), value=done)
                self.progress_var.set(f"{label} · {done}/{total}")
        except queue.Empty:
            pass
        try:
            while True:
                future, on_success = self.result_queue.get_nowait()
                self.busy = False
                self.progress_bar.stop()
                self.progress_bar.configure(mode="determinate", maximum=100, value=0)
                self.progress_var.set("")
                try:
                    result = future.result()
                except Exception as exc:
                    self._handle_error(exc)
                else:
                    try:
                        if on_success:
                            on_success(result)
                    except Exception as exc:
                        # Un error en un callback tampoco detiene el sondeo.
                        self._handle_error(exc, communication=False)
                if self.close_started:
                    self._destroy_app(None)
                    return
                self._sync_controls()
        except queue.Empty:
            pass
        if self.closing and not self.busy:
            self._finish_close()
            if self.close_started and self.dev is None:
                return
        self._poll_id = self.after(40, self._poll_async_results)

    def _handle_error(self, exc, communication=True):
        self.log(str(exc), "error")
        if communication and getattr(self, "_activity", "") == "Programando IMEM…":
            self.program_var.set("Carga incompleta o sin confirmar. Revisa la conexión y vuelve a leer IMEM.")
        if communication and isinstance(exc, DebuggerError) and not isinstance(exc, (HexFileError, WishboneError)):
            if self.dev:
                self.faulted = True
                self.sample_var.set("Captura anterior · error")
                self._render_imem()
        if not self.closing:
            messagebox.showerror("No se completó la operación", str(exc), parent=self)

    def refresh_ports(self):
        if self.busy or self.closing:
            return
        if list_ports is None:
            self.port_combo["values"] = ()
            self.log("Para usar UART instala: python -m pip install pyserial.", "warning")
            return
        try:
            ports = sorted(list_ports.comports(), key=lambda p: p.device)
        except Exception as exc:
            self.log(f"No se pudieron enumerar los puertos: {exc}", "error")
            return
        names = [p.device for p in ports]
        self.port_combo["values"] = names
        if names and not self.port_var.get():
            self.port_var.set(names[0])
        self.log("Puertos: " + ", ".join(f"{p.device} ({p.description})" for p in ports) if ports else "No se detectaron puertos. Puedes escribir la ruta manualmente.")

    @staticmethod
    def _read_observation(dev):
        return dev.snapshot(halt_if_running=False), dev.read_all_registers(halt_if_running=False)

    def toggle_connection(self):
        if self.busy or self.closing:
            return
        if self.dev and self.dev.connected:
            dev = self.dev
            def disconnected(_):
                self.dev = None
                self.faulted = False
                self._clear_session()
                self.log("Puerto cerrado. Desconectar no envía RESET ni HALT.")
            self._submit(dev.close, disconnected, "Desconectando…")
            return
        port = self.port_var.get().strip()
        if not port:
            messagebox.showwarning("Selecciona un puerto", "Selecciona o escribe el puerto de la Nexys 3.", parent=self)
            return
        try:
            baud = self._parse_int(self.baud_var.get())
            if not 1 <= baud <= 4000000:
                raise ValueError("La velocidad UART debe estar entre 1 y 4000000 baudios.")
        except ValueError as exc:
            self._handle_error(exc, False)
            return
        def job():
            dev = RV32IDebugger(port=port, baudrate=baud, timeout=1.0)
            try:
                dev.connect()
                dev.ping()
                # Abrir el puerto no informa run_mode: HALT lo establece.
                dev.halt()
                return dev, self._read_observation(dev)
            except Exception:
                dev.close()
                raise
        def connected(result):
            self.dev, observation = result
            self.faulted = False
            self._clear_session()
            self._display_observation(observation)
            self.log(f"Conectado a {port} @ {baud} 8N1. IMEM: {self.dev.imem_bytes} bytes; DMEM: {self.dev.dmem_bytes} bytes. CPU detenida.", "ok")
        self._submit(job, connected, f"Conectando a {port}…")

    def do_ping(self):
        dev = self._require_device()
        if dev:
            self._submit(dev.ping, lambda _: self.log("PING correcto · identificador RV32 y versión 1.0.", "ok"), "Comprobando PING…")

    def _cpu_action(self, action):
        dev = self._require_device(paused=action in ("step", "refresh"))
        if dev is None:
            return
        was_running = dev.running
        def job():
            if action != "refresh":
                getattr(dev, action)()
            return self._read_observation(dev)
        def success(observation):
            if action == "reset":
                self.clear_history()
            self._display_observation(observation)
            if action == "step" or (action == "halt" and was_running):
                self._record_step(observation[0], "STEP" if action == "step" else "HALT/RUN")
            messages = {"step": f"STEP · ejecutado PC 0x{observation[0].last_pc:08X}.",
                        "halt": "CPU detenida. Captura y registros actualizados.",
                        "reset": "RESET · PC reiniciado. Registros releídos (el RTL conserva su contenido).",
                        "refresh": "CPU y registros actualizados."}
            self.log(messages[action], "ok")
        self._submit(job, success, {"step": "Ejecutando una instrucción…", "halt": "Deteniendo CPU…", "reset": "Reiniciando PC…", "refresh": "Leyendo CPU y registros…"}[action])

    def do_step(self):
        self._cpu_action("step")

    def do_reset(self):
        self._cpu_action("reset")

    def do_halt(self):
        self._cpu_action("halt")

    def refresh_cpu_state(self):
        self._cpu_action("refresh")

    def refresh_registers(self):
        self.refresh_cpu_state()

    def do_run(self):
        dev = self._require_device(paused=True)
        if dev is None:
            return
        def success(_):
            self.sample_var.set("Captura anterior · RUN")
            self._render_imem()
            self.log("RUN activo. La vista conserva la última captura; F6 detiene y actualiza.", "ok")
        self._submit(dev.run, success, "Activando RUN…")

    def _clear_session(self):
        self.snapshot_value = None
        self.register_values = None
        self.changed_registers.clear()
        self.imem_values.clear()
        self.imem_is_preview = False
        self.imem_source = "Sin lectura"
        for name in ("pc", "out", "instr", "last_pc", "last_out", "last_instr"):
            getattr(self, f"{name}_var").set("0x--------")
        self.decoded_var.set("Esperando una instrucción")
        self.last_decoded_var.set("Sin captura de ejecución")
        self.decode_detail_var.set("Conecta la placa para leer el estado.")
        self.sample_var.set("Sin captura")
        self.program_var.set("Archivo seleccionado; revisa la vista previa antes de cargar." if self.hex_path_var.get().strip() else "Ningún archivo seleccionado")
        self.clear_history()
        self._render_registers()
        self._render_imem()

    def _display_snapshot(self, snapshot):
        self.snapshot_value = snapshot
        for name in ("pc", "out", "instr", "last_pc", "last_out", "last_instr"):
            getattr(self, f"{name}_var").set(f"0x{getattr(snapshot, name):08X}")
        decoded = decode_instruction(snapshot.instr, snapshot.pc)
        self.decoded_var.set(decoded.text)
        parts = [f"Tipo {decoded.kind}", f"opcode {snapshot.instr & 0x7F:07b}"]
        for role in ("rd", "rs1", "rs2"):
            index = getattr(decoded, role)
            if index is not None:
                parts.append(f"{role} x{index}/{ABI_NAMES[index]}")
        if decoded.immediate is not None:
            parts.append(f"imm {decoded.immediate}")
        self.decode_detail_var.set("  ·  ".join(parts))
        self.last_decoded_var.set(decode_instruction(snapshot.last_instr, snapshot.last_pc).text)
        self.sample_var.set("Captura · " + time.strftime("%H:%M:%S"))
        self._render_imem()

    def _display_observation(self, observation):
        snapshot, registers = observation
        self.changed_registers = {i for i, value in enumerate(registers)
                                  if self.register_values is not None and value != self.register_values[i]}
        self.register_values = list(registers)
        self._display_snapshot(snapshot)
        self._render_registers()

    def _render_registers(self):
        if not hasattr(self, "reg_tree"):
            return
        selected = self.reg_tree.selection()
        yview = self.reg_tree.yview()
        self.reg_tree.delete(*self.reg_tree.get_children())
        query = self.filter_var.get().strip().lower()
        count = 0
        for i in range(32):
            if query and query not in f"x{i} {ABI_NAMES[i]}".lower():
                continue
            if self.only_changed_var.get() and i not in self.changed_registers:
                continue
            value = self.register_values[i] if self.register_values is not None else None
            values = (f"x{i}", ABI_NAMES[i], f"0x{value:08X}" if value is not None else "0x--------",
                      str(value) if value is not None else "—", str(signed(value)) if value is not None else "—",
                      "CAMBIÓ" if i in self.changed_registers else "Constante" if i == 0 else "—")
            tag = "changed" if i in self.changed_registers else "odd" if count % 2 else "even"
            self.reg_tree.insert("", "end", iid=str(i), values=values, tags=(tag,))
            count += 1
        if selected and self.reg_tree.exists(selected[0]):
            self.reg_tree.selection_set(selected[0])
        if yview:
            self.reg_tree.yview_moveto(yview[0])
        self.reg_count_var.set(f"{count}/32 · {len(self.changed_registers)} cambios")

    def _record_step(self, snapshot, event):
        self.history_count += 1
        self.history.appendleft((self.history_count, event, f"0x{snapshot.last_pc:08X}", f"0x{snapshot.last_instr:08X}",
                                 decode_instruction(snapshot.last_instr, snapshot.last_pc).text, f"0x{snapshot.last_out:08X}"))
        self.trace_tree.delete(*self.trace_tree.get_children())
        for i, values in enumerate(self.history):
            self.trace_tree.insert("", "end", values=values, tags=("pc" if i == 0 else "odd" if i % 2 else "even",))
        self.step_count_var.set(f"{len(self.history)} capturas")

    def clear_history(self):
        self.history.clear()
        self.history_count = 0
        self.trace_tree.delete(*self.trace_tree.get_children())
        self.step_count_var.set("0 capturas")

    def save_history_log(self):
        """Guarda el historial de ejecución en un archivo .log legible."""
        if not self.history:
            self.log("El historial de pasos está vacío.", "warning")
            return

        timestamp = time.strftime("%Y%m%d_%H%M%S")
        path = filedialog.asksaveasfilename(
            parent=self,
            title="Guardar historial de ejecución",
            defaultextension=".log",
            initialfile=f"rv32i_historial_{timestamp}.log",
            filetypes=[("Archivo de log", "*.log"), ("Texto", "*.txt")],
        )
        if not path:
            return

        port = self.dev.port if self.dev and self.dev.connected else self.port_var.get().strip() or "Sin conexión"
        baud = self.baud_var.get().strip() or "N/E"

        lines = [
            "RV32I DEBUGGER - HISTORIAL DE EJECUCIÓN",
            "=" * 78,
            f"Fecha:   {time.strftime('%Y-%m-%d %H:%M:%S')}",
            f"Puerto:  {port}",
            f"UART:    {baud} baudios, 8N1",
            f"Capturas: {len(self.history)}",
            "",
            f"{'#':>4}  {'Acción':<10} {'PC ejecutado':<12} {'Instrucción':<12} {'OUT capturado':<13}  Ensamblador",
            "-" * 100,
        ]

        # self.history almacena la captura más reciente al inicio.
        # El archivo se guarda de la más antigua a la más reciente.
        for number, event, pc, instr, asm, wb in reversed(self.history):
            lines.append(
                f"{number:>4}  {event:<10} {pc:<12} {instr:<12} {wb:<13}  {asm}"
            )

        lines.extend([
            "",
            "-" * 100,
            "Fin del historial.",
            "",
        ])

        self._save_text(path, "\n".join(lines))
        self.log(f"Historial guardado: {len(self.history)} capturas.", "ok")

    def _display_memory(self, words, source, preview=False):
        self.imem_values = dict(words)
        self.imem_source = source
        self.imem_is_preview = preview
        self._render_imem()

    def _render_imem(self):
        if not hasattr(self, "imem_tree"):
            return
        selection = self.imem_tree.selection()
        yview = self.imem_tree.yview()
        self.imem_tree.delete(*self.imem_tree.get_children())
        observed = self.snapshot_value and not self.imem_is_preview and not self.faulted and self.dev and not self.dev.running
        for i, (address, word) in enumerate(sorted(self.imem_values.items())):
            marker, tag = "", "odd" if i % 2 else "even"
            if observed and address == self.snapshot_value.pc:
                marker, tag = "PC >", "pc"
            elif observed and self.snapshot_value.last_instr and address == self.snapshot_value.last_pc:
                marker, tag = "LAST", "last"
            self.imem_tree.insert("", "end", iid=str(address), tags=(tag,), values=(i + 1, marker, f"0x{address:08X}", f"0x{word:08X}",
                                  word.to_bytes(4, "little").hex(" ").upper(), decode_instruction(word, address).text))
        if selection and self.imem_tree.exists(selection[0]):
            self.imem_tree.selection_set(selection[0])
        if yview:
            self.imem_tree.yview_moveto(yview[0])
        prefix = "VISTA PREVIA · archivo local" if self.imem_is_preview else self.imem_source
        self.memory_caption_var.set(
            f"{prefix} · {len(self.imem_values)} palabras · {len(self.imem_values) * 4} bytes"
        )

    def _select_imem(self, _event=None):
        selected = self.imem_tree.selection()
        if selected and not self.busy:
            address = int(selected[0])
            self.imem_addr_var.set(f"0x{address:08X}")
            self.imem_data_var.set(f"0x{self.imem_values[address]:08X}")

    def _imem_input(self, write=False):
        address = self._parse_int(self.imem_addr_var.get())
        RV32IDebugger._validate_imem_address(address)
        data = self._parse_int(self.imem_data_var.get()) if write else 0
        if not 0 <= data <= 0xFFFFFFFF:
            raise ValueError("La palabra debe estar entre 0 y 0xFFFFFFFF.")
        return address, data

    def read_imem_manual(self):
        dev = self._require_device(paused=True)
        if dev is None:
            return
        try:
            address, _ = self._imem_input()
        except ValueError as exc:
            self._handle_error(exc, False)
            return
        def success(value):
            if self.imem_is_preview:
                self.imem_values.clear()
            self.imem_is_preview = False
            self.imem_source = "FPGA · lectura UART"
            self.imem_values[address] = value
            self.imem_data_var.set(f"0x{value:08X}")
            self._render_imem()
            self.log(f"IMEM[0x{address:08X}] = 0x{value:08X}", "ok")
        self._submit(lambda: dev.read_imem(address), success, "Leyendo palabra de IMEM…")

    def write_imem_manual(self):
        dev = self._require_device(paused=True)
        if dev is None:
            return
        try:
            address, data = self._imem_input(write=True)
        except ValueError as exc:
            self._handle_error(exc, False)
            return
        def job():
            dev.write_imem(address, data)
            actual = dev.read_imem(address)
            if actual != data:
                raise ProtocolError(f"Verificación incorrecta en 0x{address:08X}: escrito 0x{data:08X}, leído 0x{actual:08X}.")
            return actual, self._read_observation(dev)
        def success(result):
            actual, observation = result
            if self.imem_is_preview:
                self.imem_values.clear()
            self.imem_values[address] = actual
            self.imem_is_preview = False
            self.imem_source = "FPGA · lectura UART"
            self._display_observation(observation)
            self.log(f"Escritura verificada · [0x{address:08X}] = 0x{actual:08X}.", "ok")
        self._submit(job, success, "Escribiendo y verificando IMEM…")

    def browse_hex(self):
        if self.busy or self.closing:
            return
        path = filedialog.askopenfilename(parent=self, title="Abrir programa HEX", filetypes=[("Archivo HEX", "*.hex"), ("Todos los archivos", "*.*")])
        if path:
            self.hex_path_var.set(path)
            self.notebook.select(self.imem_tab)
            self.preview_hex()

    def _hex_image(self):
        path = Path(self.hex_path_var.get().strip())
        if not path.is_file():
            raise HexFileError("Selecciona un archivo .hex existente.")
        base, image = RV32IDebugger.parse_hex_file(path)
        if self.hex_base_var.get().strip():
            base = self._parse_int(self.hex_base_var.get())
        RV32IDebugger._validate_imem_address(base)
        original = len(image)
        image += bytes((-len(image)) % 4)
        if base + len(image) > 0x10000:
            raise HexFileError("El contenido del HEX excede la ventana IMEM de 64 KiB.")
        words = [(base + i, int.from_bytes(image[i:i + 4], "little")) for i in range(0, len(image), 4)]
        return path, base, original, words

    def preview_hex(self):
        if self.busy or self.closing:
            return
        try:
            path, base, original, words = self._hex_image()
        except (ValueError, OSError, DebuggerError) as exc:
            self.program_var.set(f"Archivo sin validar · {exc}")
            self._handle_error(exc, False)
            return
        self._display_memory(words, "Archivo", preview=True)
        padded = len(words) * 4 - original
        self.program_var.set(f"{path.name} · {original} bytes · {len(words)} palabras · base 0x{base:08X} · relleno: {padded} bytes. Aún no programado.")
        self.log(f"Vista previa: {path.name}. No se ha escrito en la FPGA.")

    def load_hex(self):
        dev = self._require_device(paused=True)
        if dev is None:
            return

        try:
            path, base, _original, programmed_words = self._hex_image()
        except (ValueError, OSError, DebuggerError) as exc:
            self._handle_error(exc, False)
            return

        verify = self.verify_var.get()

        def progress(done, total, label):
            self.progress_queue.put((done, total, label))

        def job():
            # La verificacion, si esta habilitada, ya se realiza dentro
            # de load_hex(). No se hace un dump completo adicional.
            report = dev.load_hex(
                path,
                base_address=base,
                verify=verify,
                reset_after=True,
                progress=progress,
                cancel=self.cancel_event,
            )

            # Conservamos solamente la lectura del estado del CPU para
            # actualizar PC, instruccion y registros de la interfaz.
            observation = self._read_observation(dev)

            return report, observation

        def success(result):
            report, observation = result

            self.clear_history()

            # La tabla conserva las palabras del archivo cargado.
            memory_source = (
                "FPGA · programa verificado"
                if report.verified
                else "FPGA · programa enviado"
            )
            self._display_memory(programmed_words, memory_source)
            self._display_observation(observation)

            verdict = (
                "verificado"
                if report.verified
                else "sin verificación"
            )

            self.program_var.set(
                f"Cargado · {Path(report.filename).name} · "
                f"{report.programmed_bytes} bytes · "
                f"{report.words} palabras · {verdict} · PC reiniciado."
            )

            self.log(
                f"Programa cargado: {report.words} palabras en "
                f"0x{report.base_address:08X}; {verdict}. "
                "CPU detenida.",
                "ok" if report.verified else "warning",
            )

        self._submit(job, success, "Programando IMEM…")

    def dump_imem(self):
        dev = self._require_device(paused=True)
        if dev is None:
            return

        try:
            start_address = self._parse_int(self.imem_addr_var.get())
            RV32IDebugger._validate_imem_address(start_address)
            word_count = self._parse_int(self.dump_words_var.get())
            if word_count <= 0:
                raise ValueError("La cantidad de palabras debe ser mayor que cero.")
        except ValueError as exc:
            self._handle_error(exc, False)
            return

        def progress(done, total, label):
            self.progress_queue.put((done, total, label))

        def success(words):
            self._display_memory(words, "FPGA · lectura UART")
            self.log(
                f"IMEM leída: {len(words)} palabras ({len(words) * 4} bytes) "
                f"desde 0x{start_address:08X}.",
                "ok",
            )

        self._submit(
            lambda: dev.dump_imem(
                start_address=start_address,
                word_count=word_count,
                progress=progress,
                cancel=self.cancel_event,
            ),
            success,
            "Leyendo bloque de IMEM…",
        )

    def export_registers(self):
        if self.register_values is None:
            self.log("Lee los registros antes de exportarlos.", "warning")
            return
        path = filedialog.asksaveasfilename(parent=self, defaultextension=".csv", initialfile="registros_rv32i.csv", filetypes=[("CSV", "*.csv")])
        if path:
            try:
                with open(path, "w", newline="", encoding="utf-8-sig") as file:
                    writer = csv.writer(file)
                    writer.writerow(["registro", "abi", "hex", "sin_signo", "con_signo", "origen", "captura"])
                    for i, value in enumerate(self.register_values):
                        writer.writerow([f"x{i}", ABI_NAMES[i], f"0x{value:08X}", value, signed(value),
                                         "UART", self.sample_var.get()])
                self.log(f"Registros exportados: {path}", "ok")
            except OSError as exc:
                self._handle_error(exc, False)

    def export_imem(self):
        if not self.imem_values:
            self.log("Lee la IMEM o previsualiza un HEX antes de exportar.", "warning")
            return
        path = filedialog.asksaveasfilename(parent=self, defaultextension=".hex", initialfile="imem_preview.hex" if self.imem_is_preview else "imem_rv32i.hex", filetypes=[("Archivo HEX", "*.hex")])
        if path:
            lines = [f"// RV32I · {self.memory_caption_var.get()}\n"]
            previous = None
            for address, word in sorted(self.imem_values.items()):
                if previous is None or address != previous + 4:
                    lines.append(f"@{address:08X}\n")
                lines.append(word.to_bytes(4, "little").hex(" ").upper() + "\n")
                previous = address
            self._save_text(path, "".join(lines))

    def save_log(self):
        path = filedialog.asksaveasfilename(parent=self, defaultextension=".log", initialfile="rv32i_debugger.log", filetypes=[("Log", "*.log"), ("Texto", "*.txt")])
        if path:
            self._save_text(path, self.log_text.get("1.0", "end-1c"))

    def _save_text(self, path, text):
        try:
            Path(path).write_text(text, encoding="utf-8")
            self.log(f"Archivo guardado: {path}", "ok")
        except OSError as exc:
            self._handle_error(exc, False)

    def show_help(self):
        messagebox.showinfo("RV32I · Guía rápida", (
            "1. Elige puerto y baudios; Conectar comprueba PING y envía HALT.\n"
            "2. En Memoria y programa abre un HEX de bytes o palabras de 32 bits, revisa la vista previa y carga a la FPGA.\n"
            "3. F10 ejecuta una instrucción y relee CPU + registros. F5 inicia RUN; F6 detiene y captura.\n\n"
            "Ctrl+R: reiniciar PC · Ctrl+O: abrir HEX · Ctrl+1/2/3: cambiar pestaña.\n"
            "Ctrl+C: copiar fila · Clic sobre un valor grande: copiar hexadecimal.\n"
            "En Historial de pasos, 'Guardar historial .log' exporta todas las capturas STEP y HALT/RUN "
            "en orden cronológico, con fecha, puerto y configuración UART.\n\n"
            "OUT es combinacional; LAST OUT corresponde a la última instrucción ejecutada. "
            "El historial contiene pasos solicitados y el final de RUN, no cada ciclo de ejecución libre.\n\n"
            "HEX: bytes (93 00 50 00) o palabras de 32 bits (00500093), directivas @ y comentarios # ; //. "
            "Las palabras se convierten internamente a little-endian. Base vacía respeta el archivo. "
            "Los huecos y la última palabra incompleta se rellenan con cero. La GUI consulta el tamaño de IMEM; "
            "la capacidad física disponible depende de tu RTL.\n\n"
            "RESET no borra registros ni IMEM en el RTL adjunto. El ensamblador es una interpretación local; "
            "no añade instrucciones al hardware. La pestaña Wishbone permite acceder a DMEM (base 0x00010000).\n\n"
            "Para UART: python -m pip install pyserial.\n"
            "Después de un error UART, desconecta y comprueba el reset global de la placa antes de reconectar."
        ), parent=self)

    def _on_close(self):
        if self.closing:
            return
        self.closing = True
        self.cancel_event.set()
        self._sync_controls()
        if not self.busy:
            self._finish_close()

    def _finish_close(self):
        if self.close_started:
            return
        self.close_started = True
        if self.dev is None:
            self._destroy_app(None)
            return
        self.busy = True
        # El cierre va después de la operación pendiente en el mismo trabajador.
        future = self.executor.submit(self.dev.close)
        future.add_done_callback(lambda f: self.result_queue.put((f, self._destroy_app)))

    def _destroy_app(self, _result):
        if self._destroyed:
            return
        self._destroyed = True
        self.executor.shutdown(wait=False, cancel_futures=True)
        if self._poll_id:
            self.after_cancel(self._poll_id)
        self.destroy()


def main():
    if sys.platform == "win32":
        # Evita la ampliación borrosa de Windows en pantallas de alta densidad.
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass
    app = RV32IDebuggerGUI()
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
