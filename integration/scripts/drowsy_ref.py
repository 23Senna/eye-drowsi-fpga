"""Reference model of perclos_unit + drowsy_fsm (contract for rtl/drowsy_fsm.v).

This is the contract for the RTL: on every CNN `done`, the hardware performs exactly one `step()`,
in this order, using the values updated in the same step:

  eye_eff    = eye_prev if low_conf else eye           (low-confidence frames hold the previous state)
  out_bit    = window[W-1]                              (the frame falling out of the window)
  window     = (window << 1 | eye_eff) & (2^W - 1)
  count      = count + eye_eff - out_bit                (= number of 1s in window)
  closed_run = eye_eff ? sat(closed_run + 1) : 0        (sat = saturate at 2^RUN_BITS - 1)
  open_run   = eye_eff ? 0 : sat(open_run + 1)
  perclos    = (count * 25) >> 3                        (= count * 100 / 32, exact for W = 32)
  state      = MICROSLEEP                       if closed_run >= SLEEP_RUN
               else if state == MICROSLEEP:     open_run >= WAKE_RUN -> (DROWSY if count > DROWSY_OFF else AWAKE)
               else if state == AWAKE:          count >= DROWSY_ON   -> DROWSY
               else if state == DROWSY:         count <= DROWSY_OFF  -> AWAKE
  eye_prev   = eye_eff
Reset: window = count = closed_run = open_run = 0, eye_prev = OPEN, state = AWAKE.
"""
# drowsiness parameters (same values as the RTL defaults in rtl/drowsy_fsm.v)
OPEN, CLOSED = 0, 1
W = 32                        # window length in frames (3.2 s at 10 frames/s)
DROWSY_ON = 13                # closed_count >= 13 (~40 %) -> DROWSY
DROWSY_OFF = 6                # closed_count <= 6 (~20 %)  -> back to AWAKE
SLEEP_RUN = 8                 # closed_run >= 8 frames (0.8 s) -> MICROSLEEP
WAKE_RUN = 10                 # open_run >= 10 frames (1 s) ends MICROSLEEP
RUN_BITS = 6                  # closed_run / open_run saturate at 2**RUN_BITS - 1
AWAKE, DROWSY, MICROSLEEP = 0, 1, 2
STATE_NAMES = ("AWAKE", "DROWSY", "MICROSLEEP")

assert W == 32, "perclos = (count * 25) >> 3 is only exact for W = 32"


class DrowsyRef:
    RUN_MAX = (1 << RUN_BITS) - 1
    MASK = (1 << W) - 1

    def __init__(self):
        self.window = self.count = self.closed_run = self.open_run = 0
        self.eye_prev = OPEN
        self.state = AWAKE

    def step(self, eye, low_conf=False):
        eye_eff = self.eye_prev if low_conf else int(eye)
        out_bit = (self.window >> (W - 1)) & 1
        self.window = ((self.window << 1) | eye_eff) & self.MASK
        self.count += eye_eff - out_bit
        self.closed_run = min(self.closed_run + 1, self.RUN_MAX) if eye_eff else 0
        self.open_run = 0 if eye_eff else min(self.open_run + 1, self.RUN_MAX)
        perclos = (self.count * 25) >> 3

        if self.closed_run >= SLEEP_RUN:
            self.state = MICROSLEEP
        elif self.state == MICROSLEEP:
            if self.open_run >= WAKE_RUN:
                self.state = DROWSY if self.count > DROWSY_OFF else AWAKE
        elif self.state == AWAKE:
            if self.count >= DROWSY_ON:
                self.state = DROWSY
        elif self.state == DROWSY:
            if self.count <= DROWSY_OFF:
                self.state = AWAKE
        self.eye_prev = eye_eff
        assert self.count == bin(self.window).count("1")
        return dict(eye_eff=eye_eff, count=self.count, closed_run=self.closed_run,
                    open_run=self.open_run, perclos=perclos, state=self.state)


def run(eyes, low_conf=None):
    """Feed a sequence of eye states (0 OPEN / 1 CLOSED); returns the per-step outputs."""
    ref = DrowsyRef()
    low_conf = low_conf or [False] * len(eyes)
    return [ref.step(e, lc) for e, lc in zip(eyes, low_conf)]


def state_name(s):
    return STATE_NAMES[s]
