// read only the regions referenced by the active NPU device.
import { readfile, glob, basename } from 'fs';

function cells(path) {
	let data = readfile(path);
	if (data == null || length(data) % 4)
		return null;
	let result = [];
	for (let i = 0; i < length(data); i += 4) {
		let value = 0;
		for (let j = 0; j < 4; j++)
			value = value * 256 + ord(substr(data, i + j, 1));
		push(result, value);
	}
	return result;
}

function regions(dt, device) {
	let base = dt + '/reserved-memory';
	let ac = cells(base + '/#address-cells'), sc = cells(base + '/#size-cells');
	let refs = cells(device + '/of_node/memory-region');
	if (!ac || length(ac) != 1 || !sc || length(sc) != 1 ||
	    (ac[0] != 1 && ac[0] != 2) || (sc[0] != 1 && sc[0] != 2) ||
	    !refs || !length(refs))
		return [];
	let result = [], seen = {};
	for (let ref in refs) {
		if (seen[ref])
			continue;
		seen[ref] = true;
		let node = null;
		for (let path in glob(base + '/*')) {
			let ph = cells(path + '/phandle') ?? cells(path + '/linux,phandle');
			if (ph && length(ph) == 1 && ph[0] == ref) {
				node = path;
				break;
			}
		}
		if (!node)
			return []; // Unknown/partial data must not look like zero usage.
		let reg = cells(node + '/reg'), width = ac[0] + sc[0];
		if (!reg || !length(reg) || length(reg) % width)
			return [];
		for (let offset = 0; offset < length(reg); offset += width) {
			let start = 0, size = 0;
			for (let i = 0; i < ac[0]; i++)
				start = start * 4294967296 + reg[offset + i];
			for (let i = 0; i < sc[0]; i++)
				size = size * 4294967296 + reg[offset + ac[0] + i];
			// This UI serves 32-bit AN758x physical address maps. Refuse an
			// unsupported range instead of displaying wrapped arithmetic.
			if (start < 0 || start > 4294967295 || size <= 0 ||
			    size > 4294967296 || start + size > 4294967296)
				return [];
			push(result, { name: split(basename(node), '@')[0],
				start: sprintf('0x%08x', start),
				end: sprintf('0x%08x', start + size - 1),
				bytes: size, size: sprintf('%d KiB', size / 1024) });
		}
	}
	return result;
}

let dt = ARGV[0] ?? '/sys/firmware/devicetree/base';
let device = ARGV[1] ?? (glob('/sys/bus/platform/drivers/airoha-npu/*.npu')[0]);
printf('%J\n', device ? regions(dt, device) : []);
