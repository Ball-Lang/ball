
namespace {

BallDyn isEven(int64_t n);
BallDyn isOdd(int64_t n);

BallDyn isEven(int64_t n) {
    auto& input = n;
    if ((n == static_cast<int64_t>(0))) {
        return BallDyn(true);
    }
    return isOdd((n - static_cast<int64_t>(1)));
    return BallDyn();
}

BallDyn isOdd(int64_t n) {
    auto& input = n;
    if ((n == static_cast<int64_t>(0))) {
        return BallDyn(false);
    }
    return isEven((n - static_cast<int64_t>(1)));
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(isEven(static_cast<int64_t>(0)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(isOdd(static_cast<int64_t>(7)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(isEven(static_cast<int64_t>(10)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(isOdd(static_cast<int64_t>(10)))) << std::endl;
    return 0;
}
