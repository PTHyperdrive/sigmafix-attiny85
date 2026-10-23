
PROGRAMMER ?= usbtiny
MICRONUCLEUS ?= micronucleus

ASFLAGS = -mmcu=attiny85 -x assembler-with-cpp -nostartfiles -nostdlib

all: sigmafix_t85.hex sigmafix_digispark.hex sigmafix_digispark_instant.hex

sigmafix_t85.elf: sigmafix_t85.S
	avr-gcc $(ASFLAGS) -o $@ $<

sigmafix_digispark.elf: sigmafix_t85.S
	avr-gcc $(ASFLAGS) -DDIGISPARK -o $@ $<

sigmafix_digispark_instant.elf: sigmafix_t85.S
	avr-gcc $(ASFLAGS) -DDIGISPARK -DBYPASS_BOOTLOADER -o $@ $<

%.hex: %.elf
	avr-objcopy -O ihex -j .text $< $@

flash: sigmafix_t85.hex
	avrdude -p attiny85 -c $(PROGRAMMER) -U flash:w:$< \
		-U lfuse:w:0xe2:m \
		-U hfuse:w:0xdd:m \
		-U efuse:w:0xff:m

flash-digispark: sigmafix_digispark.hex
	$(MICRONUCLEUS) --run $<

flash-digispark-instant: sigmafix_digispark_instant.hex
	$(MICRONUCLEUS) --run $<

clean:
	rm -f *.hex *.elf

.PHONY: all flash flash-digispark flash-digispark-instant clean
