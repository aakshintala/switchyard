// #681, red first: two tests mutate the same process-global var with no
// serialisation. A Barrier forces the interleaving (no sleeps): both sides
// set before either reads, so the process env can only hold one value and at
// least one side must observe the other's write and fail.
#[cfg(test)]
mod tests {
    use std::sync::Barrier;

    const RACE_VAR: &str = "DELEGATE_TEST_ENV_SERIAL_681";
    static RENDEZVOUS: Barrier = Barrier::new(2);

    fn race_once(expected: &str) {
        unsafe { std::env::set_var(RACE_VAR, expected) };
        RENDEZVOUS.wait();
        let got = std::env::var(RACE_VAR).unwrap_or_default();
        RENDEZVOUS.wait();
        unsafe { std::env::remove_var(RACE_VAR) };
        assert_eq!(
            got, expected,
            "concurrent env mutation without the shared helper"
        );
    }

    #[test]
    fn env_race_first_writer_wins() {
        race_once("first");
    }

    #[test]
    fn env_race_second_writer_wins() {
        race_once("second");
    }
}
