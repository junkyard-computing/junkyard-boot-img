# iio

- **AOSP path**: `private/google-modules/soc/gs/drivers/iio/power/`
- **Mainline counterpart**: **NONE**
- **Status**: not-ported
- **Boot-relevance score**: 2/10

## What it does

ODPM — **On-Device Power Monitor** — driver. Two flavors (`odpm.c`, `odpm-whi.c`). Talks to s2mpg10/12/14 PMIC family (gs101/gs201/zuma respectively) over the ACPM-I2C path to read per-rail energy/power accumulators and exposes them as IIO channels via configfs. Used by ODPM userspace tools (and Pixel battery-stats infra) for watt-hour accounting per subdomain.

## Mainline equivalent

None. The s2mpg* PMIC drivers themselves aren't in mainline. Mainline IIO has generic INA231 / power-monitor drivers but nothing for the Samsung PMIC ODPM block.

## Differences vs AOSP / what's missing

Everything. **Hard-blocked by ACPM-I2C absence** (see `gs-i2c.md`) — even if this driver were ported, it can't reach the PMIC ODPM registers without `i2c-acpm.c`.

## Boot-relevance reasoning

2/10. Pure observability; battery accounting is a nice-to-have, never on a boot path. Hard-blocked by ACPM-I2C anyway.

