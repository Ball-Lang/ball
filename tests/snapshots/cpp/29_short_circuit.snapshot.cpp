
namespace {

BallDyn sideEffect(std::string tag, bool v);

BallDyn sideEffect(std::string tag, bool v) {
    std::cout << ball_to_string(("eval:"s + ball_to_string(tag))) << std::endl;
    return v;
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string((sideEffect("a"s, false) && sideEffect("b"s, true)))) << std::endl;
    std::cout << ball_to_string(ball_to_string((sideEffect("c"s, true) || sideEffect("d"s, false)))) << std::endl;
    std::cout << ball_to_string(ball_to_string((sideEffect("e"s, true) && sideEffect("f"s, false)))) << std::endl;
    return 0;
}
