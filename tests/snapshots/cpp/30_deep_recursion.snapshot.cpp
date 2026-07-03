
namespace {

BallDyn sumTo(int64_t n);
BallDyn power(int64_t base, int64_t exp_);

BallDyn sumTo(int64_t n) {
    auto& input = n;
    if ((n <= static_cast<int64_t>(0))) {
        return BallDyn(static_cast<int64_t>(0));
    }
    return (n + sumTo((n - static_cast<int64_t>(1))));
    return BallDyn();
}

BallDyn power(int64_t base, int64_t exp_) {
    if ((exp_ == static_cast<int64_t>(0))) {
        return BallDyn(static_cast<int64_t>(1));
    }
    return (base * power(base, (exp_ - static_cast<int64_t>(1))));
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(sumTo(static_cast<int64_t>(10)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(sumTo(static_cast<int64_t>(100)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(power(static_cast<int64_t>(2), static_cast<int64_t>(10)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(power(static_cast<int64_t>(3), static_cast<int64_t>(4)))) << std::endl;
    return 0;
}
