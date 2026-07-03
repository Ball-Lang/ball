
namespace {


} // namespace

int main() {
    auto a = BallDyn(static_cast<int64_t>(10));
    auto b = BallDyn(static_cast<int64_t>(3));
    std::cout << ball_to_string(ball_to_string((a + b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a - b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a * b))) << std::endl;
    std::cout << ball_to_string(ball_to_string((a / b))) << std::endl;
    std::cout << ball_to_string(ball_to_string([&](int64_t _a, int64_t _b){ auto _r = _a % _b; return _r < 0 ? _r + (_b < 0 ? -_b : _b) : _r; }(static_cast<int64_t>(a), static_cast<int64_t>(b)))) << std::endl;
    return 0;
}
