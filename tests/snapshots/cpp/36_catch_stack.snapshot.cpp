
namespace {


} // namespace

int main() {
    try {
        throw _ball_make_exception("Exception"s, "boom"s);
    } catch (const std::exception& __ball_e) {
        auto e = _ball_caught_to_dyn(__ball_e);
        std::string stack = "<stack trace unavailable>"s;
        std::cout << ball_to_string(ball_to_string(e)) << std::endl;
        std::cout << ball_to_string((BallDyn((ball_length(ball_to_string(stack)) > static_cast<int64_t>(0)) ? BallDyn("has-stack"s) : BallDyn("no-stack"s)))) << std::endl;
    }
    return 0;
}
