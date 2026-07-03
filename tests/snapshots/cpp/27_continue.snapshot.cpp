
namespace {


} // namespace

int main() {
    auto count = BallDyn(static_cast<int64_t>(0));
    for (auto i = static_cast<int64_t>(1); (i <= static_cast<int64_t>(10)); ball_assign(i, (i + static_cast<int64_t>(1)))) {
        if (([&](int64_t _a, int64_t _b){ auto _r = _a % _b; return _r < 0 ? _r + (_b < 0 ? -_b : _b) : _r; }(static_cast<int64_t>(i), static_cast<int64_t>(static_cast<int64_t>(2))) == static_cast<int64_t>(0))) {
            continue;
        }
        if ((i == static_cast<int64_t>(7))) {
            break;
        }
        ball_assign(count, (count + static_cast<int64_t>(1)));
        std::cout << ball_to_string(ball_to_string(i)) << std::endl;
    }
    std::cout << ball_to_string(("count="s + ball_to_string(count))) << std::endl;
    return 0;
}
