
namespace {


} // namespace

int main() {
    try {
        [](const std::string& s) -> int64_t { try { return std::stoll(s); } catch (const std::exception&) { throw BallException("FormatException"s, "FormatException: "s + s); } }("not a number"s);
    } catch (const BallException& __ball_e) {
        if (__ball_e.type_name == "FormatException"s) {
            const BallException& e = __ball_e;
            std::cout << ball_to_string("caught-format"s) << std::endl;
        }
        else {
            throw;
        }
    } catch (const std::exception& __ball_e) {
        throw;
    }
    try {
        throw _ball_make_exception("Exception"s, "boom"s);
    } catch (const std::exception& __ball_e) {
        auto e = _ball_caught_to_dyn(__ball_e);
        std::cout << ball_to_string(e) << std::endl;
    }
    std::cout << ball_to_string("after"s) << std::endl;
    return 0;
}
