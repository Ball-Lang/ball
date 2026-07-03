
namespace {


} // namespace

int main() {
    try {
        try {
            throw _ball_make_exception("Exception"s, "inner-boom"s);
        } catch (const std::exception& __ball_e) {
            auto e = _ball_caught_to_dyn(__ball_e);
            std::cout << ball_to_string(("inner caught: "s + ball_to_string(e))) << std::endl;
            throw;
        }
    } catch (const std::exception& __ball_e) {
        auto e = _ball_caught_to_dyn(__ball_e);
        std::cout << ball_to_string(("outer caught: "s + ball_to_string(e))) << std::endl;
    }
    std::cout << ball_to_string("after"s) << std::endl;
    return 0;
}
